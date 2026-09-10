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

/// Resolves each resource separately so advanced selections can coexist with a bundle.
/// The caller supplies bundle location and readability; core checks need no files.
public enum TranscriptionResourceResolver {
    public static let executableFilename = "whisper-cli"

    public static func resolve(
        explicitExecutableURL: URL? = nil,
        explicitModelURL: URL? = nil,
        bundledResourceDirectory: URL?,
        homeDirectory: URL,
        isReadable: (URL) -> Bool
    ) -> TranscriptionConfiguration {
        let executable = resourceURL(
            explicit: explicitExecutableURL,
            bundled: bundledResourceDirectory?.appendingPathComponent(executableFilename),
            fallback: URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
            isReadable: isReadable
        )
        let model = resourceURL(
            explicit: explicitModelURL,
            bundled: bundledResourceDirectory?.appendingPathComponent(WhisperModelCatalog.defaultModelFilename),
            fallback: WhisperModelCatalog.defaultModelURL(homeDirectory: homeDirectory),
            isReadable: isReadable
        )
        return TranscriptionConfiguration(executableURL: executable, modelURL: model, language: "en")
    }

    private static func resourceURL(
        explicit: URL?,
        bundled: URL?,
        fallback: URL,
        isReadable: (URL) -> Bool
    ) -> URL {
        if let explicit, isReadable(explicit) { return explicit }
        if let bundled, isReadable(bundled) { return bundled }
        // Preserve the existing missing-resource error paths when nothing is installed.
        return fallback
    }
}

public enum WhisperModelCatalog {
    public static let defaultModelFilename = "ggml-tiny.en.bin"

    public static func defaultModelURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".content-agents", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent(defaultModelFilename)
    }

    public static func isModelFilename(_ filename: String) -> Bool {
        filename.hasPrefix("ggml-") && filename.hasSuffix(".bin")
    }

    public static func displayName(for filename: String) -> String {
        filename
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
    }
}

public func normalizeTranscript(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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

public enum Hotkey {
    public static let rightOption = RightOptionHotkey()

    public enum Event: Equatable, Sendable {
        case flagsChanged(
            keyCode: UInt16,
            optionIsDown: Bool,
            controlIsDown: Bool,
            commandIsDown: Bool
        )
        case keyDown(
            keyCode: UInt16,
            controlIsDown: Bool,
            optionIsDown: Bool,
            isRepeat: Bool
        )
        case otherMouseDown(buttonNumber: Int64)
    }

    public struct RightOptionHotkey: Sendable {
        public let keyCode: UInt16 = 61

        public func matchesPress(keyCode: UInt16, optionIsDown: Bool) -> Bool {
            keyCode == self.keyCode && optionIsDown
        }
    }

    public static func matchesFallback(
        keyCode: UInt16,
        controlIsDown: Bool,
        optionIsDown: Bool,
        isRepeat: Bool
    ) -> Bool {
        keyCode == 49 && controlIsDown && optionIsDown && !isRepeat
    }

    public static func matchesRightOptionPress(
        keyCode: UInt16,
        optionIsDown: Bool,
        controlIsDown: Bool,
        commandIsDown: Bool
    ) -> Bool {
        !controlIsDown
            && !commandIsDown
            && rightOption.matchesPress(keyCode: keyCode, optionIsDown: optionIsDown)
    }

    public static func matchesMiddleMouseButton(buttonNumber: Int64) -> Bool {
        buttonNumber == 2
    }

    public static func matchesToggle(_ event: Event) -> Bool {
        switch event {
        case .flagsChanged(let keyCode, let optionIsDown, let controlIsDown, let commandIsDown):
            return matchesRightOptionPress(
                keyCode: keyCode,
                optionIsDown: optionIsDown,
                controlIsDown: controlIsDown,
                commandIsDown: commandIsDown
            )
        case .keyDown(let keyCode, let controlIsDown, let optionIsDown, let isRepeat):
            return matchesFallback(
                keyCode: keyCode,
                controlIsDown: controlIsDown,
                optionIsDown: optionIsDown,
                isRepeat: isRepeat
            )
        case .otherMouseDown(let buttonNumber):
            return matchesMiddleMouseButton(buttonNumber: buttonNumber)
        }
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
    public var cleanupCommand: URL?
    public var cleanupEnabled: Bool

    public init(
        transcription: TranscriptionConfiguration,
        cleanupCommand: URL? = nil,
        cleanupEnabled: Bool = false
    ) {
        self.transcription = transcription
        self.cleanupCommand = cleanupCommand
        self.cleanupEnabled = cleanupEnabled
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
