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
    private var whisperModelMenu: NSMenu!
    private var whisperModelMenuItem: NSMenuItem!
    private var pastePermissionMenuItem: NSMenuItem!
    private var hotkeyPermissionMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var testPasteMenuItem: NSMenuItem!
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var globalEventMonitor: Any?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Local Dictation")
        statusItem.button?.title = "LD"
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle Local Cleanup", action: #selector(toggleCleanup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Whisper Executable…", action: #selector(chooseWhisperExecutable), keyEquivalent: ""))
        whisperModelMenu = NSMenu()
        whisperModelMenu.delegate = self
        whisperModelMenuItem = NSMenuItem(title: "Select Whisper Model", action: nil, keyEquivalent: "")
        whisperModelMenuItem.submenu = whisperModelMenu
        menu.addItem(whisperModelMenuItem)
        menu.addItem(NSMenuItem(title: "Use Automatic Whisper Resources", action: #selector(useAutomaticWhisperResources), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Cleanup Executable…", action: #selector(chooseCleanupExecutable), keyEquivalent: ""))
        microphoneMenu = NSMenu()
        microphoneMenu.delegate = self
        microphoneMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneMenuItem.submenu = microphoneMenu
        menu.addItem(microphoneMenuItem)
        pastePermissionMenuItem = NSMenuItem(title: "Paste automation: Checking…", action: nil, keyEquivalent: "")
        pastePermissionMenuItem.isEnabled = false
        menu.addItem(pastePermissionMenuItem)
        hotkeyPermissionMenuItem = NSMenuItem(title: "Hotkeys: Checking…", action: nil, keyEquivalent: "")
        hotkeyPermissionMenuItem.isEnabled = false
        menu.addItem(hotkeyPermissionMenuItem)
        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        menu.addItem(launchAtLoginMenuItem)
        testPasteMenuItem = NSMenuItem(
            title: "Test Paste into Frontmost App",
            action: #selector(testPaste),
            keyEquivalent: ""
        )
        menu.addItem(testPasteMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Local Dictation", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        indicatorWindow = StatusIndicatorWindow()
        controller = DictationController(
            statusItem: statusItem,
            indicatorWindow: indicatorWindow,
            inputDeviceManager: inputDeviceManager
        )
        refreshMicrophoneMenu()
        refreshWhisperModelMenu()
        refreshPastePermissionStatus()
        refreshHotkeyPermissionStatus()
        refreshLaunchAtLoginStatus()
        requestMicrophonePermission()
        requestInputMonitoringPermission()
        installCarbonFallbackHotkey()
        installGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventTap, let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            CFMachPortInvalidate(eventTap)
        }
        globalEventMonitor = nil
        if let carbonHotKey { UnregisterEventHotKey(carbonHotKey) }
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
    }

    private func installCarbonFallbackHotkey() {
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
            statusItem.button?.title = "LD!"
            statusItem.button?.toolTip = "Local Dictation — could not register ⌘⇧Space"
            return
        }

        let hotKeyID = EventHotKeyID(signature: 0x4C444943, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKey
        )
        if hotKeyStatus != noErr {
            NSLog("Local Dictation: Carbon hotkey registration failed: %d", hotKeyStatus)
            statusItem.button?.title = "LD!"
            statusItem.button?.toolTip = "Local Dictation — could not register ⌘⇧Space"
        } else {
            NSLog("Local Dictation: Carbon hotkey ⌘⇧Space registered")
        }
    }

    private func installGlobalHotkey() {
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
            if globalEventMonitor != nil {
                statusItem.button?.title = "LD"
                statusItem.button?.toolTip = "Local Dictation — right Option and middle mouse ready"
                return
            }
            if carbonHotKey == nil {
                statusItem.button?.title = "LD!"
                statusItem.button?.toolTip = "Local Dictation — enable Accessibility and Input Monitoring access"
            } else {
                statusItem.button?.title = "LD"
                statusItem.button?.toolTip = "Local Dictation — right Option and middle mouse ready"
            }
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
            guard let self,
                  let hotkeyEvent = hotkeyEvent(from: event),
                  Hotkey.matchesToggle(hotkeyEvent) else {
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

    func reenableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            installGlobalHotkey()
        }
    }

    @objc private func toggleCleanup() {
        controller.toggleCleanup()
    }

    @objc private func chooseWhisperExecutable() {
        chooseFile(defaultKey: "transcriptionExecutable", message: "Choose the local whisper-cli executable")
    }

    @objc private func chooseWhisperModel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        UserDefaults.standard.set(path, forKey: "transcriptionModel")
        refreshWhisperModelMenu()
    }

    @objc private func chooseOtherWhisperModel() {
        chooseFile(defaultKey: "transcriptionModel", message: "Choose a local Whisper model for English transcription")
        refreshWhisperModelMenu()
    }

    @objc private func useAutomaticWhisperResources() {
        UserDefaults.standard.removeObject(forKey: "transcriptionExecutable")
        UserDefaults.standard.removeObject(forKey: "transcriptionModel")
        refreshWhisperModelMenu()
    }

    @objc private func chooseCleanupExecutable() {
        chooseFile(defaultKey: "cleanupExecutable", message: "Choose a local cleanup executable")
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === microphoneMenu { refreshMicrophoneMenu() }
        if menu === whisperModelMenu { refreshWhisperModelMenu() }
        if menu === statusItem.menu {
            if eventTap == nil && globalEventMonitor == nil {
                installGlobalHotkey()
            }
            refreshPastePermissionStatus()
            refreshHotkeyPermissionStatus()
            refreshLaunchAtLoginStatus()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            let alert = NSAlert()
            alert.messageText = "Launch at Login Could Not Be Changed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func refreshLaunchAtLoginStatus() {
        guard launchAtLoginMenuItem != nil else { return }
        let status: LaunchAtLoginStatus
        switch SMAppService.mainApp.status {
        case .enabled:
            status = .enabled
        case .notRegistered:
            status = .disabled
        case .requiresApproval:
            status = .requiresApproval
        case .notFound:
            status = .unavailable
        @unknown default:
            status = .unavailable
        }
        launchAtLoginMenuItem.state = status.isEnabled ? .on : .off
        switch status {
        case .enabled:
            launchAtLoginMenuItem.toolTip = "Local Dictation will open automatically when you log in."
        case .disabled:
            launchAtLoginMenuItem.toolTip = "Open Local Dictation automatically when you log in."
        case .requiresApproval:
            launchAtLoginMenuItem.toolTip = "Approve Local Dictation in System Settings to enable launch at login."
        case .unavailable:
            launchAtLoginMenuItem.toolTip = "Launch at login is unavailable for this app build."
        }
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

    private func refreshWhisperModelMenu() {
        guard whisperModelMenu != nil else { return }
        whisperModelMenu.removeAllItems()

        let currentModelURL = LocalCommandTranscriber.defaultConfiguration().modelURL
        let modelDirectory = WhisperModelCatalog.defaultModelURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).deletingLastPathComponent()
        var modelURLs = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            WhisperModelCatalog.isModelFilename(url.lastPathComponent)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isReadableFile(atPath: url.path)
        } ?? []

        if FileManager.default.isReadableFile(atPath: currentModelURL.path),
           !modelURLs.contains(currentModelURL) {
            modelURLs.append(currentModelURL)
        }
        modelURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for modelURL in modelURLs {
            let item = NSMenuItem(
                title: WhisperModelCatalog.displayName(for: modelURL.lastPathComponent),
                action: #selector(chooseWhisperModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = modelURL.path
            item.state = modelURL.path == currentModelURL.path ? .on : .off
            whisperModelMenu.addItem(item)
        }

        if modelURLs.isEmpty {
            let unavailable = NSMenuItem(title: "No installed Whisper models", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            whisperModelMenu.addItem(unavailable)
        }

        whisperModelMenu.addItem(.separator())
        let chooseOther = NSMenuItem(
            title: "Choose Other Whisper Model…",
            action: #selector(chooseOtherWhisperModel),
            keyEquivalent: ""
        )
        chooseOther.target = self
        whisperModelMenu.addItem(chooseOther)

        if FileManager.default.isReadableFile(atPath: currentModelURL.path) {
            whisperModelMenuItem.title = "Select Whisper Model: \(WhisperModelCatalog.displayName(for: currentModelURL.lastPathComponent))"
        } else {
            whisperModelMenuItem.title = "Select Whisper Model: Missing"
        }
    }

    private func refreshPastePermissionStatus() {
        guard pastePermissionMenuItem != nil else { return }
        let pasteAccess = PasteAutomationAccess(accessibilityTrusted: AXIsProcessTrusted())
        if pasteAccess.canPaste {
            pastePermissionMenuItem.title = "Paste automation: Ready"
            pastePermissionMenuItem.toolTip = "Accessibility access is available."
        } else {
            pastePermissionMenuItem.title = "Paste automation: Enable Accessibility"
            pastePermissionMenuItem.toolTip = "Enable LocalDictation under Privacy & Security → Accessibility."
        }
    }

    private func refreshHotkeyPermissionStatus() {
        guard hotkeyPermissionMenuItem != nil else { return }
        if eventTap != nil || globalEventMonitor != nil {
            hotkeyPermissionMenuItem.title = "Hotkeys: Ready"
            hotkeyPermissionMenuItem.toolTip = "Physical right Option and middle mouse button toggle dictation."
        } else if CGPreflightListenEventAccess() {
            hotkeyPermissionMenuItem.title = "Hotkeys: Relaunch LocalDictation"
            hotkeyPermissionMenuItem.toolTip = "Input Monitoring is allowed; relaunch LocalDictation to register the event tap."
        } else {
            hotkeyPermissionMenuItem.title = "Hotkeys: Enable Input Monitoring"
            hotkeyPermissionMenuItem.toolTip = "Enable LocalDictation under Privacy & Security → Input Monitoring, then relaunch it."
        }
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

    @objc private func testPaste() {
        let currentProcessID = NSRunningApplication.current.processIdentifier
        let targetProcessID: pid_t?
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != currentProcessID {
            targetProcessID = frontmostApplication.processIdentifier
        } else {
            targetProcessID = nil
        }
        guard ClipboardTextInserter().insert("LocalDictation paste test", into: targetProcessID) else {
            refreshPastePermissionStatus()
            let alert = NSAlert()
            alert.messageText = "Paste automation is not ready"
            alert.informativeText = "The test text was left on the clipboard. Check the Paste automation status and enable the listed macOS permissions."
            alert.runModal()
            return
        }
        refreshPastePermissionStatus()
    }

    private func microphoneMenuTitle(for info: InputDeviceInfo) -> String {
        if InputDeviceSelector.isHyperX(info.name) { return "\(info.name) (preferred)" }
        if InputDeviceSelector.isMacBookBuiltIn(info.name) { return "\(info.name) (fallback)" }
        return info.name
    }

    private func chooseFile(defaultKey: String, message: String) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: defaultKey)
        }
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
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
    guard status == noErr, hotKeyID.signature == 0x4C444943, hotKeyID.id == 1 else { return noErr }
    NSLog("Local Dictation: Carbon hotkey event received")
    let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in app.triggerFromGlobalHotkey() }
    return noErr
}

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

    guard let userInfo,
          let hotkeyEvent = hotkeyEvent(from: type, event: event),
          Hotkey.matchesToggle(hotkeyEvent) else {
        return Unmanaged.passUnretained(event)
    }

    let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    NSLog("Local Dictation: global event tap hotkey event received")
    Task { @MainActor in app.triggerFromGlobalHotkey() }
    if case .otherMouseDown = hotkeyEvent {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

private func hotkeyEvent(from type: CGEventType, event: CGEvent) -> Hotkey.Event? {
    let flags = event.flags
    switch type {
    case .flagsChanged:
        return .flagsChanged(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            optionIsDown: flags.contains(.maskAlternate),
            controlIsDown: flags.contains(.maskControl),
            commandIsDown: flags.contains(.maskCommand)
        )
    case .keyDown:
        return .keyDown(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            controlIsDown: flags.contains(.maskControl),
            optionIsDown: flags.contains(.maskAlternate),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    case .otherMouseDown:
        return .otherMouseDown(buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber))
    default:
        return nil
    }
}

private func hotkeyEvent(from event: NSEvent) -> Hotkey.Event? {
    let flags = event.modifierFlags
    switch event.type {
    case .flagsChanged:
        return .flagsChanged(
            keyCode: event.keyCode,
            optionIsDown: flags.contains(.option),
            controlIsDown: flags.contains(.control),
            commandIsDown: flags.contains(.command)
        )
    case .keyDown:
        return .keyDown(
            keyCode: event.keyCode,
            controlIsDown: flags.contains(.control),
            optionIsDown: flags.contains(.option),
            isRepeat: event.isARepeat
        )
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
    private let recorder: AudioRecorder
    private let inserter = ClipboardTextInserter()
    private var state: DictationState = .idle
    private var targetProcessID: pid_t?

    init(
        statusItem: NSStatusItem,
        indicatorWindow: StatusIndicatorWindow,
        inputDeviceManager: AudioInputDeviceManager
    ) {
        self.statusItem = statusItem
        self.indicatorWindow = indicatorWindow
        self.inputDeviceManager = inputDeviceManager
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
                    var text = try LocalCommandTranscriber().transcribe(audioURL: audioURL, configuration: configuration)
                    if UserDefaults.standard.bool(forKey: "cleanupEnabled") {
                        text = (try? LocalCommandCleaner().clean(text)) ?? text
                    }
                    let normalized = normalizeTranscript(text)
                    guard !normalized.isEmpty else { throw DictationError.emptyTranscript }
                    DispatchQueue.main.async { self?.complete(normalized) }
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

    func toggleCleanup() {
        let enabled = !UserDefaults.standard.bool(forKey: "cleanupEnabled")
        UserDefaults.standard.set(enabled, forKey: "cleanupEnabled")
        showStatus(enabled ? "Local cleanup enabled." : "Local cleanup disabled.")
    }

    private func showStatus(_ message: String) {
        NSLog("Local Dictation: %@", message)
        let alert = NSAlert()
        alert.messageText = "Local Dictation"
        alert.informativeText = message
        alert.runModal()
    }
}

private enum DictationError: LocalizedError {
    case emptyTranscript
    var errorDescription: String? { "No speech was detected." }
}
