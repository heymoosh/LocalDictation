import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case inserting
    case failed

    public func canTransition(to next: DictationState) -> Bool {
        switch (self, next) {
        case (.idle, .recording),
             (.recording, .transcribing),
             (.transcribing, .inserting),
             // A recording that held no speech has nothing to insert, so it
             // ends quietly instead of being reported as a failure.
             (.transcribing, .idle),
             (.inserting, .idle),
             (_, .failed),
             (.failed, .idle):
            return true
        default:
            return false
        }
    }
}

public struct DictationIndicatorPresentation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ready
        case recording
        case processing
        case failed
    }

    public let kind: Kind
    public let title: String
    public let accessibilityLabel: String

    public init(kind: Kind, title: String, accessibilityLabel: String) {
        self.kind = kind
        self.title = title
        self.accessibilityLabel = accessibilityLabel
    }

    public init(state: DictationState) {
        switch state {
        case .idle:
            self.init(kind: .ready, title: "Ready", accessibilityLabel: "Local Dictation is ready")
        case .recording:
            self.init(kind: .recording, title: "Recording", accessibilityLabel: "Local Dictation is recording")
        case .transcribing, .inserting:
            self.init(
                kind: .processing,
                title: "Processing",
                accessibilityLabel: "Local Dictation is processing the transcription"
            )
        case .failed:
            self.init(
                kind: .failed,
                title: "Needs attention",
                accessibilityLabel: "Local Dictation needs attention"
            )
        }
    }
}

/// The menu bar item doubles as the only way to stop a recording without the
/// hotkey, so its title has to follow the state instead of always reading
/// "Start Dictation". The two processing states have nothing to toggle, so they
/// report progress and disable the command rather than beeping at a click.
public struct DictationMenuCommand: Equatable, Sendable {
    public let title: String
    public let isEnabled: Bool

    public init(title: String, isEnabled: Bool) {
        self.title = title
        self.isEnabled = isEnabled
    }

    public init(state: DictationState) {
        switch state {
        case .idle, .failed:
            self.init(title: "Start Dictation", isEnabled: true)
        case .recording:
            self.init(title: "Stop Dictation", isEnabled: true)
        case .transcribing:
            self.init(title: "Transcribing…", isEnabled: false)
        case .inserting:
            self.init(title: "Inserting Text…", isEnabled: false)
        }
    }
}

public struct DictationIndicatorSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct DictationIndicatorFrame: Equatable, Sendable {
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    public var maxX: Double {
        originX + width
    }

    public var maxY: Double {
        originY + height
    }
}

public enum DictationIndicatorLayout {
    public static let compactSize = DictationIndicatorSize(width: 32, height: 32)
    public static let recordingSize = DictationIndicatorSize(width: 32, height: 128)

    public static func size(for state: DictationState) -> DictationIndicatorSize {
        state == .recording ? recordingSize : compactSize
    }

    /// Restores a saved indicator location without allowing a recording-size
    /// or malformed frame to become the next launch's idle frame. The
    /// top edge is preserved because recording expands downward.
    public static func compactFrame(from persistedFrame: DictationIndicatorFrame) -> DictationIndicatorFrame {
        DictationIndicatorFrame(
            originX: persistedFrame.originX,
            originY: persistedFrame.maxY - compactSize.height,
            width: compactSize.width,
            height: compactSize.height
        )
    }
}

public struct TranscriptionConfiguration: Equatable, Sendable {
    public var executableURL: URL
    public var modelURL: URL
    public var language: String

    public init(executableURL: URL, modelURL: URL, language: String = "en") {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.language = language
    }

    public func arguments(for audioURL: URL) -> [String] {
        ["-m", modelURL.path, "-l", language, "-nt", "-np", audioURL.path]
    }
}

/// Resolves the transcription engine without any user-facing choice: the app
/// always runs the bundled resources when present, and otherwise the first
/// readable install location. Homebrew's Apple-silicon prefix is probed before
/// `/usr/local` because a Mac with both prefixes has the native build in
/// `/opt/homebrew` and an x86_64 build in `/usr/local` that would run ~10x
/// slower under Rosetta. The caller supplies bundle location and readability;
/// core checks need no files.
public enum TranscriptionResourceResolver {
    public static let executableFilename = "whisper-cli"

    /// Ordered engine locations. Apple-silicon Homebrew first, then Intel
    /// Homebrew, which is also the correct prefix on an Intel Mac.
    public static let executableSearchPaths = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
    ]

    public static func resolve(
        bundledResourceDirectory: URL?,
        homeDirectory: URL,
        isReadable: (URL) -> Bool
    ) -> TranscriptionConfiguration {
        let executable = firstReadable(
            candidates: [bundledResourceDirectory?.appendingPathComponent(executableFilename)]
                + executableSearchPaths.map(URL.init(fileURLWithPath:)),
            isReadable: isReadable
        )
        let model = firstReadable(
            candidates: [
                bundledResourceDirectory?.appendingPathComponent(WhisperModelCatalog.defaultModelFilename),
                WhisperModelCatalog.defaultModelURL(homeDirectory: homeDirectory),
            ],
            isReadable: isReadable
        )
        return TranscriptionConfiguration(executableURL: executable, modelURL: model, language: "en")
    }

    /// Falls back to the last candidate when nothing is readable, so a missing
    /// install still surfaces the existing missing-resource error naming a real path.
    private static func firstReadable(candidates: [URL?], isReadable: (URL) -> Bool) -> URL {
        let present = candidates.compactMap { $0 }
        return present.first(where: isReadable) ?? present[present.count - 1]
    }
}

public enum WhisperModelCatalog {
    public static let defaultModelFilename = "ggml-base.en.bin"

    public static func defaultModelURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".content-agents", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent(defaultModelFilename)
    }

}

/// One past transcript, kept so a user who forgot to paste can recover it.
public struct TranscriptHistoryEntry: Equatable, Sendable, Codable {
    public let text: String
    public let date: Date

    public init(text: String, date: Date) {
        self.text = text
        self.date = date
    }

    /// A menu row is one short line, so the preview collapses the newlines a
    /// dictated paragraph carries and cuts anything past `limit` characters.
    public func menuTitle(limit: Int = 60) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

public enum TranscriptHistory {
    /// Deep enough to cover a forgotten paste from earlier in the day, shallow
    /// enough that the list stays a menu rather than a database.
    public static let limit = 30

    /// Newest first, so the entry a user is most likely reaching for sits at the
    /// top of the menu. Repeating the same transcript back to back replaces the
    /// earlier copy instead of filling the list with duplicates.
    public static func appending(
        _ text: String,
        to entries: [TranscriptHistoryEntry],
        date: Date
    ) -> [TranscriptHistoryEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        var updated = entries
        if updated.first?.text == trimmed { updated.removeFirst() }
        updated.insert(TranscriptHistoryEntry(text: trimmed, date: date), at: 0)
        return Array(updated.prefix(limit))
    }
}

public func normalizeTranscript(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Whisper labels the sounds it hears but cannot turn into words: "[BLANK_AUDIO]"
/// when the microphone caught nothing, "[MUSIC]" or "(wind blowing)" for
/// background noise. Those labels are a note about the recording, not something
/// the user said, so they are removed before anything is pasted.
public enum NonSpeechAnnotation {
    /// Square brackets are dropped whatever they hold, because dictating a
    /// sentence does not produce them. Parentheses and asterisks can come from
    /// real speech, so those are only dropped when they name a sound from this
    /// list.
    private static let soundWords: Set<String> = [
        "applause", "audio", "background", "beep", "blank", "breathing",
        "buzzing", "chuckles", "clears", "clicking", "coughs", "crosstalk",
        "grunts", "inaudible", "laughs", "laughter", "music", "noise", "pause",
        "sighs", "silence", "singing", "sound", "sounds", "static", "throat",
        "typing", "unintelligible", "whispering", "wind",
    ]

    /// Returns the words the user actually spoke, with the sound labels taken
    /// out and the leftover spacing tidied.
    public static func strip(from text: String) -> String {
        var kept = ""
        var chunk = ""
        var closing: Character?
        var chunkNeedsSoundWord = false

        for character in text {
            if let expected = closing {
                chunk.append(character)
                guard character == expected else { continue }
                if !isSoundLabel(chunk, requiresSoundWord: chunkNeedsSoundWord) {
                    kept += chunk
                }
                chunk = ""
                closing = nil
                continue
            }

            switch character {
            case "[":
                closing = "]"
                chunkNeedsSoundWord = false
            case "(":
                closing = ")"
                chunkNeedsSoundWord = true
            case "*":
                closing = "*"
                chunkNeedsSoundWord = true
            default:
                kept.append(character)
                continue
            }
            chunk = String(character)
        }

        // A label that never closed is a half-transcribed line, not a note about
        // the recording, so keep it rather than swallow the tail of a sentence.
        kept += chunk
        return normalizeTranscript(kept)
    }

    private static func isSoundLabel(_ chunk: String, requiresSoundWord: Bool) -> Bool {
        guard requiresSoundWord else { return true }
        return chunk
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { soundWords.contains(String($0)) }
    }
}

/// The text that should reach the user's document, or nil when the recording
/// held nothing but silence and background noise. Pasting "[BLANK_AUDIO]" into
/// someone's work is worse than pasting nothing at all.
public func deliverableTranscript(from text: String) -> String? {
    let spoken = NonSpeechAnnotation.strip(from: text)
    return spoken.isEmpty ? nil : spoken
}

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable

    public var isEnabled: Bool {
        self == .enabled
    }
}

public struct HotkeyModifiers: OptionSet, Sendable, Codable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// Menu-bar order, matching how macOS prints a shortcut.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "\u{2303}" }
        if contains(.option) { text += "\u{2325}" }
        if contains(.shift) { text += "\u{21E7}" }
        if contains(.command) { text += "\u{2318}" }
        return text
    }
}

/// One user-chosen way to toggle dictation. Three shapes cover everything the
/// app can observe: tapping a modifier on its own, a key with modifiers, and a
/// non-primary mouse button.
public enum HotkeyBinding: Equatable, Sendable, Codable {
    /// A modifier pressed and released by itself, identified by key code so the
    /// left and right keys stay distinct.
    case modifierTap(keyCode: UInt16)
    /// `label` is captured from the keyboard at record time, so the shortcut
    /// prints correctly on any layout without a key-code table.
    case keyCombination(keyCode: UInt16, modifiers: HotkeyModifiers, label: String)
    case mouseButton(buttonNumber: Int64)

    public static let defaults: [HotkeyBinding] = [
        .modifierTap(keyCode: 61),
        .mouseButton(buttonNumber: 2),
    ]

    /// Which modifier flag a modifier key raises, so a tap can be told from a release.
    public static func modifierFlag(forKeyCode keyCode: UInt16) -> HotkeyModifiers? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default: return nil
        }
    }

    public static func modifierName(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 56: return "Left Shift"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .modifierTap(let keyCode):
            return HotkeyBinding.modifierName(forKeyCode: keyCode) ?? "Key \(keyCode)"
        case .keyCombination(_, let modifiers, let label):
            return modifiers.symbols + label
        case .mouseButton(let buttonNumber):
            return buttonNumber == 2 ? "Middle mouse button" : "Mouse button \(buttonNumber + 1)"
        }
    }

    /// Only a key combination can be registered as a system hot key, which is the
    /// one route that still works without Input Monitoring access.
    public var systemHotKey: (keyCode: UInt16, modifiers: HotkeyModifiers)? {
        guard case .keyCombination(let keyCode, let modifiers, _) = self else { return nil }
        return (keyCode, modifiers)
    }

    public func matches(_ event: Hotkey.Event) -> Bool {
        switch (self, event) {
        case (.modifierTap(let wanted), .flagsChanged(let keyCode, let modifiers)):
            // Fire on the press, not the release: the key's own flag must be down.
            guard let flag = HotkeyBinding.modifierFlag(forKeyCode: wanted) else { return false }
            return keyCode == wanted && modifiers == flag
        case (.keyCombination(let wanted, let wantedModifiers, _), .keyDown(let keyCode, let modifiers, let isRepeat)):
            // Exact modifiers, so a shortcut does not also fire with extra keys held.
            return keyCode == wanted && modifiers == wantedModifiers && !isRepeat
        case (.mouseButton(let wanted), .otherMouseDown(let buttonNumber)):
            return buttonNumber == wanted
        default:
            return false
        }
    }
}

public enum Hotkey {
    public enum Event: Equatable, Sendable {
        case flagsChanged(keyCode: UInt16, modifiers: HotkeyModifiers)
        case keyDown(keyCode: UInt16, modifiers: HotkeyModifiers, isRepeat: Bool)
        case otherMouseDown(buttonNumber: Int64)
    }

    public static func matchesToggle(_ event: Event, bindings: [HotkeyBinding]) -> Bool {
        bindings.contains { $0.matches(event) }
    }

    /// Round-trips the user's bindings through user defaults. A missing value means
    /// "never configured" and yields the defaults; a stored empty list is a real
    /// choice to have no shortcut, and is preserved.
    public static func decodeBindings(_ data: Data?) -> [HotkeyBinding] {
        guard let data, let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data) else {
            return HotkeyBinding.defaults
        }
        return decoded
    }

    public static func encodeBindings(_ bindings: [HotkeyBinding]) -> Data? {
        try? JSONEncoder().encode(bindings)
    }
}

public struct TranscriptDelivery: Equatable, Sendable {
    public let text: String
    public let keepsTranscriptOnClipboard: Bool
    public let automaticallyPastes: Bool

    public init(text: String) {
        self.text = text
        self.keepsTranscriptOnClipboard = true
        self.automaticallyPastes = true
    }
}

public struct PasteAutomationAccess: Equatable, Sendable {
    public let accessibilityTrusted: Bool

    public init(accessibilityTrusted: Bool) {
        self.accessibilityTrusted = accessibilityTrusted
    }

    public var canPaste: Bool {
        accessibilityTrusted
    }
}

public func parseTranscriptionOutput(_ output: String) -> String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
}

public struct DictationConfiguration: Equatable, Sendable {
    public var transcription: TranscriptionConfiguration

    public init(transcription: TranscriptionConfiguration) {
        self.transcription = transcription
    }
}

public struct InputDeviceInfo: Equatable, Sendable {
    public let name: String
    public let uid: String

    public init(name: String, uid: String) {
        self.name = name
        self.uid = uid
    }
}

public enum InputDevicePreference: Equatable, Sendable {
    case automatic
    case specific(uid: String)

    public init(storageValue: String?) {
        guard let storageValue,
              storageValue.hasPrefix("device:"),
              storageValue.count > "device:".count else {
            self = .automatic
            return
        }
        self = .specific(uid: String(storageValue.dropFirst("device:".count)))
    }

    public var storageValue: String {
        switch self {
        case .automatic:
            return "automatic"
        case .specific(let uid):
            return "device:\(uid)"
        }
    }
}

public enum InputDeviceSelector {
    public static func select(
        preference: InputDevicePreference,
        from devices: [InputDeviceInfo]
    ) -> InputDeviceInfo? {
        switch preference {
        case .automatic:
            return automatic(from: devices)
        case .specific(let uid):
            return devices.first(where: { $0.uid == uid }) ?? automatic(from: devices)
        }
    }

    public static func automatic(from devices: [InputDeviceInfo]) -> InputDeviceInfo? {
        devices.first(where: { isHyperX($0.name) })
            ?? devices.first(where: { isMacBookBuiltIn($0.name) })
    }

    public static func isHyperX(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("hyperx")
    }

    public static func isMacBookBuiltIn(_ name: String) -> Bool {
        let normalized = name.lowercased()
        let soundsLikeMacBook = normalized.contains("macbook")
        let soundsLikeMicrophone = normalized.contains("microphone") || normalized.contains("mic")
        return soundsLikeMacBook && soundsLikeMicrophone
    }
}
