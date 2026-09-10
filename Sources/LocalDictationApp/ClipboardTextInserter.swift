import AppKit
import ApplicationServices
import LocalDictationCore

final class ClipboardTextInserter {
    @discardableResult
    func insert(_ text: String, into processID: pid_t? = nil) -> Bool {
        let delivery = TranscriptDelivery(text: text)
        let pasteboard = NSPasteboard.general

        guard pasteboard.clearContents() != 0 else {
            NSLog("Local Dictation: could not clear the clipboard before insertion.")
            return false
        }
        guard delivery.keepsTranscriptOnClipboard,
              pasteboard.setString(delivery.text, forType: .string) else {
            NSLog("Local Dictation: could not write transcript to the clipboard.")
            return false
        }
        guard delivery.automaticallyPastes else { return true }

        // Checked without the prompt option on purpose: a system modal in the middle
        // of a paste interrupts whatever the user is dictating into. The transcript
        // still reaches the clipboard, and Settings reports the live status.
        let pasteAccess = PasteAutomationAccess(accessibilityTrusted: AXIsProcessTrusted())
        guard pasteAccess.canPaste else {
            NSLog("Accessibility permission is unavailable; transcript copied to clipboard.")
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            NSLog("Local Dictation: could not create the paste keyboard event; transcript copied to clipboard.")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        if let processID {
            keyDown.postToPid(processID)
            keyUp.postToPid(processID)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        return true
    }
}
