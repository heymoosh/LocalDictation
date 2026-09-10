import AppKit
import Carbon.HIToolbox
import LocalDictationCore

/// A button that turns whatever the user presses next into a `HotkeyBinding`.
///
/// It listens with a *local* monitor, which only sees events aimed at this app's
/// key window. That matters: local monitoring needs no Input Monitoring access, so
/// a shortcut can be recorded before any permission has been granted.
@MainActor
final class HotkeyRecorderButton: NSButton {
    private let idleTitle: String
    private let onCapture: (HotkeyBinding) -> Void
    private var monitor: Any?

    /// The modifier key currently held on its own. It becomes a `.modifierTap`
    /// binding only if it is released without another key being pressed, which is
    /// what separates "tapped Right Option" from "held Option, then pressed Space".
    private var pendingModifier: UInt16?

    init(title: String, onCapture: @escaping (HotkeyBinding) -> Void) {
        idleTitle = title
        self.onCapture = onCapture
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Recording holds a monitor, so it must not outlive the button being taken
    /// out of the window — closing Settings mid-recording lands here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    @objc private func startRecording() {
        guard monitor == nil else {
            stopRecording()
            return
        }
        title = "Press a shortcut… (Esc to cancel)"
        pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return handle(event) ? nil : event
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
        title = idleTitle
    }

    /// Returns true when the event was consumed, so it never reaches the window.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event)
        case .otherMouseDown:
            capture(.mouseButton(buttonNumber: Int64(event.buttonNumber)))
            return true
        default:
            return false
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        guard let flag = HotkeyBinding.modifierFlag(forKeyCode: event.keyCode) else { return true }
        let held = HotkeyRecorderButton.modifiers(from: event.modifierFlags)
        if held == flag {
            // Pressed on its own. Holding a second modifier clears it, because the
            // user is on their way to a combination.
            pendingModifier = event.keyCode
        } else if held.isEmpty, pendingModifier == event.keyCode {
            capture(.modifierTap(keyCode: event.keyCode))
        } else {
            pendingModifier = nil
        }
        return true
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        pendingModifier = nil
        let modifiers = HotkeyRecorderButton.modifiers(from: event.modifierFlags)
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
            stopRecording()
            return true
        }
        // A bare key would swallow that letter in every app, so require a modifier.
        guard !modifiers.isEmpty else {
            NSSound.beep()
            title = "Add a modifier — ⌘, ⌥, ⌃ or ⇧"
            return true
        }
        capture(.keyCombination(
            keyCode: event.keyCode,
            modifiers: modifiers,
            label: HotkeyRecorderButton.label(for: event)
        ))
        return true
    }

    private func capture(_ binding: HotkeyBinding) {
        stopRecording()
        onCapture(binding)
    }

    /// Nonisolated so the global event monitor's callback can reuse it.
    nonisolated static func modifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// Keys that print nothing need a name; everything else is taken straight from
    /// the keyboard, so the shortcut reads correctly on any layout.
    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_LeftArrow: return "\u{2190}"
        case kVK_RightArrow: return "\u{2192}"
        case kVK_UpArrow: return "\u{2191}"
        case kVK_DownArrow: return "\u{2193}"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default: break
        }
        let characters = (event.charactersIgnoringModifiers ?? "").uppercased()
        return characters.isEmpty ? "Key \(event.keyCode)" : characters
    }
}
