import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import LocalDictationCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var indicatorWindow: StatusIndicatorWindow!
    private let inputDeviceManager = AudioInputDeviceManager()
    private var microphoneMenu: NSMenu!
    private var microphoneMenuItem: NSMenuItem!
    private var dictationMenuItem: NSMenuItem!
    private var historyMenu: NSMenu!
    private var historyMenuItem: NSMenuItem!
    private let historyStore = TranscriptHistoryStore()
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var globalEventMonitor: Any?
    private var carbonHotKeys: [EventHotKeyRef] = []
    private var carbonHandler: EventHandlerRef?
    /// The saved shortcuts, read once per install instead of decoded from
    /// UserDefaults on every key press the event tap sees.
    private(set) var hotkeyBindings: [HotkeyBinding] = []
    private var settingsWindow: SettingsWindow?
    private let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    private var aboutWindow: AboutWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Local Dictation")
        statusItem.button?.title = "LD"
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        // The dictation command's title and enablement are set from state in
        // menuWillOpen, so AppKit's own validation would only fight it.
        menu.autoenablesItems = false
        menu.delegate = self
        dictationMenuItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(dictationMenuItem)
        menu.addItem(.separator())
        microphoneMenu = NSMenu()
        microphoneMenu.delegate = self
        microphoneMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneMenuItem.submenu = microphoneMenu
        menu.addItem(microphoneMenuItem)
        historyMenu = NSMenu()
        historyMenu.delegate = self
        historyMenuItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        historyMenuItem.submenu = historyMenu
        menu.addItem(historyMenuItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About Local Dictation", action: #selector(showAboutWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Local Dictation", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        indicatorWindow = StatusIndicatorWindow()
        controller = DictationController(
            statusItem: statusItem,
            indicatorWindow: indicatorWindow,
            inputDeviceManager: inputDeviceManager,
            historyStore: historyStore
        )
        settingsWindow = SettingsWindow(onBindingsChanged: { [weak self] in self?.reinstallHotkeys() })
        aboutWindow = AboutWindow()

        refreshMicrophoneMenu()
        requestMicrophonePermission()
        requestInputMonitoringPermission()
        requestAccessibilityPermission()
        installHotkeys()
        warmUpTranscriptionEngine()

        if !UserDefaults.standard.bool(forKey: SettingsWindow.hasShownDefaultsKey) {
            UserDefaults.standard.set(true, forKey: SettingsWindow.hasShownDefaultsKey)
            settingsWindow?.show()
        }
    }

    /// The first Whisper run after an engine or OS update spends ~17s compiling
    /// Metal shaders before it transcribes anything. Paying that once at launch,
    /// on a fraction of a second of silence, keeps it out of the first dictation.
    private func warmUpTranscriptionEngine() {
        DispatchQueue.global(qos: .utility).async {
            let configuration = LocalCommandTranscriber.defaultConfiguration()
            guard let silence = try? LocalCommandTranscriber.writeSilentWarmUpAudio() else { return }
            defer { try? FileManager.default.removeItem(at: silence) }
            _ = try? LocalCommandTranscriber().transcribe(audioURL: silence, configuration: configuration)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        uninstallHotkeys()
    }

    /// Installs whatever the user's shortcuts need. The event tap is the main
    /// route; Carbon only fills in for key combinations when the tap could not be
    /// created, because it is the one route that works without Input Monitoring.
    private func installHotkeys() {
        let bindings = SettingsWindow.bindings
        hotkeyBindings = bindings
        if !bindings.isEmpty {
            installGlobalHotkey()
            if eventTap == nil, globalEventMonitor == nil {
                installCarbonHotKeys(for: bindings)
            } else {
                // The tap came up on a later attempt, so drop the fallback rather
                // than let a key combination fire twice.
                uninstallCarbonHotKeys()
            }
        }
        refreshStatusItemAppearance()
    }

    private func uninstallHotkeys() {
        if let eventTap, let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        eventTapSource = nil
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        globalEventMonitor = nil
        uninstallCarbonHotKeys()
    }

    private func uninstallCarbonHotKeys() {
        carbonHotKeys.forEach { UnregisterEventHotKey($0) }
        carbonHotKeys = []
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHandler = nil
    }

    /// Called when Settings changes the user's shortcuts.
    func reinstallHotkeys() {
        uninstallHotkeys()
        installHotkeys()
    }

    private func refreshStatusItemAppearance() {
        // With no shortcuts saved there is nothing to listen for, so that is not a
        // warning state — the menu still starts dictation.
        let listening = SettingsWindow.bindings.isEmpty
            || eventTap != nil
            || globalEventMonitor != nil
            || !carbonHotKeys.isEmpty
        statusItem.button?.title = listening ? "LD" : "LD!"
        controller?.refreshMicrophoneStatus()
    }

    private func installCarbonHotKeys(for bindings: [HotkeyBinding]) {
        let combinations = bindings.compactMap(\.systemHotKey)
        guard carbonHotKeys.isEmpty, carbonHandler == nil, !combinations.isEmpty else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            userInfo,
            &carbonHandler
        )
        guard handlerStatus == noErr else {
            NSLog("Local Dictation: Carbon hotkey handler registration failed: %d", handlerStatus)
            return
        }

        for (index, combination) in combinations.enumerated() {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(combination.keyCode),
                carbonModifiers(combination.modifiers),
                EventHotKeyID(signature: 0x4C444943, id: UInt32(index + 1)),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                carbonHotKeys.append(reference)
            } else {
                NSLog("Local Dictation: Carbon hotkey registration failed: %d", status)
            }
        }
    }

    private func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private func installGlobalHotkey() {
        guard eventTap == nil, globalEventMonitor == nil else { return }
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
        )
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .defaultTap, eventsOfInterest: mask,
                                     callback: globalHotkeyCallback, userInfo: userInfo)
        if eventTap == nil {
            eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: mask,
                                         callback: globalHotkeyCallback, userInfo: userInfo)
        }

        guard let eventTap else {
            installGlobalEventMonitor()
            return
        }
        globalEventMonitor = nil
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            NSLog("Local Dictation: global event tap registered")
        }
    }

    private func installGlobalEventMonitor() {
        guard globalEventMonitor == nil else { return }
        guard CGPreflightListenEventAccess() else {
            NSLog("Local Dictation: global event monitor requires Input Monitoring access")
            return
        }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .otherMouseDown]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            // A monitor cannot consume the event the way the event tap can, but
            // cancelling here still stops the recording before it is missed.
            if event.type == .keyDown, event.keyCode == escapeKeyCode {
                Task { @MainActor in self.cancelRecordingIfActive() }
                return
            }
            guard let hotkeyEvent = hotkeyEvent(from: event),
                  Hotkey.matchesToggle(hotkeyEvent, bindings: MainActor.assumeIsolated { self.hotkeyBindings }) else {
                return
            }
            NSLog("Local Dictation: global monitor hotkey event received")
            Task { @MainActor in self.triggerFromGlobalHotkey() }
        }
        if globalEventMonitor == nil {
            NSLog("Local Dictation: global event monitor registration failed")
        } else {
            NSLog("Local Dictation: global event monitor registered")
        }
    }

    @objc private func toggleDictation() {
        controller.toggle()
    }

    func triggerFromGlobalHotkey() {
        toggleDictation()
    }

    /// Escape cancels a recording in progress. Returns whether it actually did
    /// so, so callers only swallow the key when there was something to cancel.
    @discardableResult
    func cancelRecordingIfActive() -> Bool {
        controller.cancelIfRecording()
    }

    func reenableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            installGlobalHotkey()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === microphoneMenu { refreshMicrophoneMenu() }
        if menu === historyMenu { refreshHistoryMenu() }
        // Input Monitoring can be granted after launch, so retry a tap that never
        // came up rather than making the user relaunch. Re-registering is safe:
        // both installers no-op when they already hold something.
        if menu === statusItem.menu {
            refreshDictationMenuItem()
            if eventTap == nil, globalEventMonitor == nil {
                installHotkeys()
            }
        }
    }

    private func refreshDictationMenuItem() {
        let command = DictationMenuCommand(state: controller.currentState)
        dictationMenuItem.title = command.title
        dictationMenuItem.isEnabled = command.isEnabled
    }

    /// Copies the chosen transcript so the user can paste it wherever they meant
    /// it to go. Pasting for them is deliberately not done here: the menu click
    /// already moved focus to this app, so there is no reliable target field.
    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func clearHistory() {
        historyStore.clear()
        refreshHistoryMenu()
    }

    private func refreshHistoryMenu() {
        historyMenu.removeAllItems()
        let entries = historyStore.recent
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.menuTitle(), action: #selector(copyHistoryEntry), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            // The row is one truncated line, so the hover text carries the rest
            // along with when it was dictated.
            item.toolTip = "\(historyDateFormatter.string(from: entry.date))\n\n\(entry.text)"
            historyMenu.addItem(item)
        }
        historyMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        historyMenu.addItem(clear)
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        guard let storageValue = sender.representedObject as? String else { return }
        UserDefaults.standard.set(storageValue, forKey: "inputDevicePreference")
        refreshMicrophoneMenu()
    }

    private func refreshMicrophoneMenu() {
        guard microphoneMenu != nil else { return }
        microphoneMenu.removeAllItems()

        let preference = InputDevicePreference(storageValue: UserDefaults.standard.string(forKey: "inputDevicePreference"))
        let automatic = NSMenuItem(
            title: "Automatic (HyperX → MacBook microphone)",
            action: #selector(chooseMicrophone(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.representedObject = InputDevicePreference.automatic.storageValue
        automatic.state = preference == .automatic ? .on : .off
        microphoneMenu.addItem(automatic)
        microphoneMenu.addItem(.separator())

        let devices = inputDeviceManager.inputDevices()
        for device in devices {
            let item = NSMenuItem(
                title: microphoneMenuTitle(for: device.info),
                action: #selector(chooseMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = InputDevicePreference.specific(uid: device.info.uid).storageValue
            item.state = preference == .specific(uid: device.info.uid) ? .on : .off
            microphoneMenu.addItem(item)
        }

        if devices.isEmpty {
            let unavailable = NSMenuItem(title: "No input microphones detected", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            microphoneMenu.addItem(unavailable)
        }

        if let selected = inputDeviceManager.selectedDevice(for: preference) {
            microphoneMenuItem.title = "Microphone: \(selected.info.name)"
        } else {
            microphoneMenuItem.title = "Microphone: No HyperX/MacBook input found"
        }
        controller?.refreshMicrophoneStatus()
    }

    private func requestMicrophonePermission() {
        guard AVAudioApplication.shared.recordPermission == .undetermined else { return }
        AVAudioApplication.requestRecordPermission { granted in
            NSLog("Local Dictation microphone permission granted: %@", granted ? "yes" : "no")
        }
    }

    private func requestInputMonitoringPermission() {
        guard !CGPreflightListenEventAccess() else { return }
        _ = CGRequestListenEventAccess()
    }

    /// Unlike Microphone and Input Monitoring above, Accessibility only shows its
    /// system alert when this call is made with the prompt option — otherwise it
    /// stays silent until something else (like a paste attempt) happens to trigger it.
    private func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func microphoneMenuTitle(for info: InputDeviceInfo) -> String {
        if InputDeviceSelector.isHyperX(info.name) { return "\(info.name) (preferred)" }
        if InputDeviceSelector.isMacBookBuiltIn(info.name) { return "\(info.name) (fallback)" }
        return info.name
    }

    @objc private func showSettingsWindow() {
        settingsWindow?.show()
    }

    @objc private func showAboutWindow() {
        aboutWindow?.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private func carbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let size = MemoryLayout<EventHotKeyID>.size
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == 0x4C444943 else { return noErr }
    NSLog("Local Dictation: Carbon hotkey event received")
    let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in app.triggerFromGlobalHotkey() }
    return noErr
}

/// Escape's key code, shared by the event tap and its NSEvent-monitor fallback.
private let escapeKeyCode: Int64 = 0x35

private func globalHotkeyCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
       let userInfo {
        let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        Task { @MainActor in app.reenableEventTap() }
    }

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

    // The tap runs on the main run loop, so it is safe to check recording
    // state synchronously here rather than hopping through a Task — the
    // return value has to decide whether to swallow Escape immediately.
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == escapeKeyCode {
        let cancelled = MainActor.assumeIsolated { app.cancelRecordingIfActive() }
        return cancelled ? nil : Unmanaged.passUnretained(event)
    }

    guard let hotkeyEvent = hotkeyEvent(from: type, event: event),
          Hotkey.matchesToggle(hotkeyEvent, bindings: MainActor.assumeIsolated { app.hotkeyBindings }) else {
        return Unmanaged.passUnretained(event)
    }

    NSLog("Local Dictation: global event tap hotkey event received")
    Task { @MainActor in app.triggerFromGlobalHotkey() }
    if case .otherMouseDown = hotkeyEvent {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

private func hotkeyEvent(from type: CGEventType, event: CGEvent) -> Hotkey.Event? {
    let modifiers = hotkeyModifiers(from: event.flags)
    switch type {
    case .flagsChanged:
        return .flagsChanged(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: modifiers
        )
    case .keyDown:
        return .keyDown(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: modifiers,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    case .otherMouseDown:
        return .otherMouseDown(buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber))
    default:
        return nil
    }
}

private func hotkeyModifiers(from flags: CGEventFlags) -> HotkeyModifiers {
    var modifiers: HotkeyModifiers = []
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    return modifiers
}

private func hotkeyEvent(from event: NSEvent) -> Hotkey.Event? {
    let modifiers = HotkeyRecorderButton.modifiers(from: event.modifierFlags)
    switch event.type {
    case .flagsChanged:
        return .flagsChanged(keyCode: event.keyCode, modifiers: modifiers)
    case .keyDown:
        return .keyDown(keyCode: event.keyCode, modifiers: modifiers, isRepeat: event.isARepeat)
    case .otherMouseDown:
        return .otherMouseDown(buttonNumber: Int64(event.buttonNumber))
    default:
        return nil
    }
}

@MainActor
private final class DictationController {
    private let statusItem: NSStatusItem
    private let indicatorWindow: StatusIndicatorWindow
    private let inputDeviceManager: AudioInputDeviceManager
    private let historyStore: TranscriptHistoryStore
    private let recorder: AudioRecorder
    private let inserter = ClipboardTextInserter()
    private var state: DictationState = .idle
    private var targetProcessID: pid_t?

    var currentState: DictationState { state }

    init(
        statusItem: NSStatusItem,
        indicatorWindow: StatusIndicatorWindow,
        inputDeviceManager: AudioInputDeviceManager,
        historyStore: TranscriptHistoryStore
    ) {
        self.statusItem = statusItem
        self.indicatorWindow = indicatorWindow
        self.inputDeviceManager = inputDeviceManager
        self.historyStore = historyStore
        self.recorder = AudioRecorder(inputDeviceManager: inputDeviceManager)
        indicatorWindow.update(for: state)
        refreshMicrophoneStatus()
    }

    func refreshMicrophoneStatus() {
        let preference = InputDevicePreference(storageValue: UserDefaults.standard.string(forKey: "inputDevicePreference"))
        let microphone = inputDeviceManager.selectedDevice(for: preference)?.info.name ?? "No HyperX/MacBook input found"
        statusItem.button?.toolTip = "Local Dictation — Microphone: \(microphone) — right Option or middle mouse (fallbacks: ⌃⌥Space, ⌘⇧Space)"
    }

    func toggle() {
        switch state {
        case .idle, .failed:
            start()
        case .recording:
            stop()
        default:
            NSSound.beep()
        }
    }

    private func start() {
        do {
            targetProcessID = frontmostTargetProcessID()
            let preference = InputDevicePreference(storageValue: UserDefaults.standard.string(forKey: "inputDevicePreference"))
            let microphone = try recorder.start(preference: preference)
            state = .recording
            indicatorWindow.update(for: state)
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            statusItem.button?.title = "REC"
            statusItem.button?.toolTip = "Recording with \(microphone.name)"
        } catch {
            targetProcessID = nil
            state = .failed
            showStatus("Microphone unavailable: \(error.localizedDescription)")
        }
    }

    /// Discards a recording in progress rather than transcribing it. Returns
    /// whether there was actually a recording to cancel.
    @discardableResult
    func cancelIfRecording() -> Bool {
        guard state == .recording else { return false }
        targetProcessID = nil
        do {
            let audioURL = try recorder.stop()
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            NSLog("Local Dictation: cancel failed to stop the recorder: %@", error.localizedDescription)
        }
        state = .idle
        indicatorWindow.update(for: state)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Local Dictation")
        statusItem.button?.title = "LD"
        refreshMicrophoneStatus()
        NSLog("Local Dictation: recording cancelled with Escape.")
        return true
    }

    private func stop() {
        // Use the app containing the input cursor at stop time. This also
        // handles switching to another text field while recording.
        targetProcessID = frontmostTargetProcessID() ?? targetProcessID
        state = .transcribing
        indicatorWindow.update(for: state)
        statusItem.button?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Transcribing")
        statusItem.button?.title = "…"
        do {
            let audioURL = try recorder.stop()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { try? FileManager.default.removeItem(at: audioURL) }
                do {
                    let configuration = LocalCommandTranscriber.defaultConfiguration()
                    let text = try LocalCommandTranscriber().transcribe(audioURL: audioURL, configuration: configuration)
                    guard let spoken = deliverableTranscript(from: text) else {
                        DispatchQueue.main.async { self?.finishWithoutSpeech() }
                        return
                    }
                    DispatchQueue.main.async { self?.complete(spoken) }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { self?.fail(message) }
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func complete(_ text: String) {
        state = .inserting
        indicatorWindow.update(for: state)
        let delivery = TranscriptDelivery(text: text)
        // Saved before the paste is attempted: a paste that silently fails is
        // precisely when the user needs to find this transcript again.
        historyStore.record(delivery.text)
        let inserted = inserter.insert(delivery.text, into: targetProcessID)
        targetProcessID = nil
        if !inserted {
            NSLog("Local Dictation: transcript copied to the clipboard; automatic paste was unavailable.")
        }
        state = .idle
        indicatorWindow.update(for: state)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Local Dictation")
        statusItem.button?.title = "LD"
        refreshMicrophoneStatus()
    }

    /// Silence and background noise end the same way an insertion does, minus
    /// the insertion: nothing is pasted, nothing is saved to history, and no
    /// alert interrupts the user. Holding the hotkey by accident should cost
    /// them a click, not a dialog.
    private func finishWithoutSpeech() {
        targetProcessID = nil
        state = .idle
        indicatorWindow.update(for: state)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Local Dictation")
        statusItem.button?.title = "LD"
        refreshMicrophoneStatus()
        NSLog("Local Dictation: no speech was detected; nothing was inserted.")
    }

    private func frontmostTargetProcessID() -> pid_t? {
        let currentProcessID = NSRunningApplication.current.processIdentifier
        guard let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostProcessID != currentProcessID else {
            return nil
        }
        return frontmostProcessID
    }

    private func fail(_ message: String) {
        targetProcessID = nil
        state = .failed
        indicatorWindow.update(for: state)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Local Dictation")
        statusItem.button?.title = "LD"
        refreshMicrophoneStatus()
        showStatus("Dictation failed: \(message)")
    }

    private func showStatus(_ message: String) {
        NSLog("Local Dictation: %@", message)
        let alert = NSAlert()
        alert.messageText = "Local Dictation"
        alert.informativeText = message
        alert.runModal()
    }
}
