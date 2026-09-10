import Foundation
import LocalDictationCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let configuration = TranscriptionConfiguration(
    executableURL: URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
    modelURL: URL(fileURLWithPath: "/tmp/base.en.bin")
)

// Synthetic URLs and an injected readability predicate: no files or engines needed.
let resourceHome = URL(fileURLWithPath: "/Users/resolver-test")
let bundleResources = URL(fileURLWithPath: "/Fixture.app/Contents/Resources")
let explicitExecutable = URL(fileURLWithPath: "/chosen/whisper-cli")
let explicitModel = URL(fileURLWithPath: "/chosen/ggml-base.en.bin")
let bundledExecutable = bundleResources.appendingPathComponent("whisper-cli")
let bundledModel = bundleResources.appendingPathComponent("ggml-tiny.en.bin")
let fallbackExecutable = URL(fileURLWithPath: "/usr/local/bin/whisper-cli")
let fallbackModel = WhisperModelCatalog.defaultModelURL(homeDirectory: resourceHome)
let resourceCases: [(name: String, hasExplicit: Bool, explicitReadable: Bool, bundleReadable: Bool)] = [
    ("explicit wins", true, true, true),
    ("unreadable explicit uses bundle", true, false, true),
    ("absent explicit uses bundle", false, false, true),
    ("unreadable candidates use fallback", true, false, false),
    ("absent explicit and unreadable bundle use fallback", false, false, false)
]
for executableCase in resourceCases {
    for modelCase in resourceCases {
        var readable = Set([fallbackExecutable, fallbackModel])
        if executableCase.explicitReadable { readable.insert(explicitExecutable) }
        if executableCase.bundleReadable { readable.insert(bundledExecutable) }
        if modelCase.explicitReadable { readable.insert(explicitModel) }
        if modelCase.bundleReadable { readable.insert(bundledModel) }
        var probes: [URL] = []
        let resolved = TranscriptionResourceResolver.resolve(
            explicitExecutableURL: executableCase.hasExplicit ? explicitExecutable : nil,
            explicitModelURL: modelCase.hasExplicit ? explicitModel : nil,
            bundledResourceDirectory: bundleResources,
            homeDirectory: resourceHome,
            isReadable: { url in
                probes.append(url)
                return readable.contains(url)
            }
        )
        let expectedExecutable = executableCase.explicitReadable ? explicitExecutable
            : executableCase.bundleReadable ? bundledExecutable : fallbackExecutable
        let expectedModel = modelCase.explicitReadable ? explicitModel
            : modelCase.bundleReadable ? bundledModel : fallbackModel
        let scenario = "executable: \(executableCase.name); model: \(modelCase.name)"
        check(resolved.executableURL == expectedExecutable, "resource precedence (\(scenario))")
        check(resolved.modelURL == expectedModel, "independent model precedence (\(scenario))")
        check(resolved.language == "en", "all resolved configurations stay English (\(scenario))")
        var expectedProbes: [URL] = []
        if executableCase.hasExplicit { expectedProbes.append(explicitExecutable) }
        if !executableCase.explicitReadable { expectedProbes.append(bundledExecutable) }
        if modelCase.hasExplicit { expectedProbes.append(explicitModel) }
        if !modelCase.explicitReadable { expectedProbes.append(bundledModel) }
        check(probes == expectedProbes, "readability checks stop at the first match (\(scenario))")
    }
}
let missingResources = TranscriptionResourceResolver.resolve(
    bundledResourceDirectory: nil,
    homeDirectory: resourceHome,
    isReadable: { _ in false }
)
check(missingResources.executableURL == fallbackExecutable, "missing bundle preserves legacy executable error path")
check(missingResources.modelURL == fallbackModel, "missing bundle preserves legacy model error path")
check(bundledModel.lastPathComponent == WhisperModelCatalog.defaultModelFilename, "bundle and fallback share tiny English identity")
let coreOnlyConfiguration = DictationConfiguration(transcription: missingResources)
check(!coreOnlyConfiguration.cleanupEnabled && coreOnlyConfiguration.cleanupCommand == nil, "core dictation needs no cleanup engine")

check(
    WhisperModelCatalog.defaultModelURL(homeDirectory: URL(fileURLWithPath: "/Users/tester")).path
        == "/Users/tester/.content-agents/whisper/ggml-tiny.en.bin",
    "Whisper defaults to the tiny English model"
)
check(WhisperModelCatalog.isModelFilename("ggml-base.en.bin"), "GGML Whisper models are discoverable")
check(!WhisperModelCatalog.isModelFilename("ggml-tiny.en.gguf"), "non-GGML Whisper files are excluded")
check(
    configuration.arguments(for: URL(fileURLWithPath: "/tmp/dictation.wav")) ==
        ["-m", "/tmp/base.en.bin", "-l", "en", "-nt", "-np", "/tmp/dictation.wav"],
    "Whisper arguments use the configured model, language, and WAV"
)
check(normalizeTranscript("  hello\nworld  ") == "hello world", "transcripts normalize whitespace")
check(normalizeTranscript("") == "", "empty transcripts remain empty")
check(DictationState.idle.canTransition(to: .recording), "idle transitions to recording")
check(DictationState.recording.canTransition(to: .transcribing), "recording transitions to transcribing")
check(DictationState.transcribing.canTransition(to: .inserting), "transcribing transitions to inserting")
check(DictationState.inserting.canTransition(to: .idle), "inserting transitions to idle")
check(!DictationState.idle.canTransition(to: .inserting), "idle cannot skip to inserting")
check(
    DictationIndicatorPresentation(state: .recording).kind == .recording,
    "recording shows the recording indicator"
)
check(
    DictationIndicatorPresentation(state: .transcribing).kind == .processing,
    "transcribing shows the processing indicator"
)
check(
    DictationIndicatorPresentation(state: .inserting).kind == .processing,
    "inserting keeps the processing indicator"
)
check(
    DictationIndicatorLayout.size(for: .idle) == DictationIndicatorSize(width: 32, height: 32),
    "idle indicator stays compact"
)
check(
    DictationIndicatorLayout.size(for: .recording) == DictationIndicatorSize(width: 32, height: 128),
    "recording indicator expands downward"
)
let compactFrame = DictationIndicatorLayout.compactFrame(
    from: DictationIndicatorFrame(
        originX: 1874,
        originY: 536,
        width: 32,
        height: 128
    )
)
check(
    compactFrame == DictationIndicatorFrame(originX: 1874, originY: 632, width: 32, height: 32),
    "persisted indicator frames preserve the top edge while normalizing to compact size"
)
check(
    Hotkey.matchesRightOptionPress(
        keyCode: 61,
        optionIsDown: true,
        controlIsDown: false,
        commandIsDown: false
    ),
    "right Option matches"
)
check(
    !Hotkey.matchesRightOptionPress(
        keyCode: 58,
        optionIsDown: true,
        controlIsDown: false,
        commandIsDown: false
    ),
    "left Option does not match"
)
check(Hotkey.matchesMiddleMouseButton(buttonNumber: 2), "middle mouse button matches")
check(!Hotkey.matchesMiddleMouseButton(buttonNumber: 0), "left mouse button does not match")
check(
    Hotkey.matchesToggle(.flagsChanged(
        keyCode: 61,
        optionIsDown: true,
        controlIsDown: false,
        commandIsDown: false
    )),
    "global right Option event matches"
)
check(Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2)), "global middle mouse event matches")
let delivery = TranscriptDelivery(text: "hello world")
check(delivery.keepsTranscriptOnClipboard, "transcripts remain on the clipboard")
check(delivery.automaticallyPastes, "transcripts are automatically pasted")
check(PasteAutomationAccess(accessibilityTrusted: true).canPaste, "paste automation accepts Accessibility access")
check(!PasteAutomationAccess(accessibilityTrusted: false).canPaste, "paste automation rejects missing Accessibility access")
check(LaunchAtLoginStatus.enabled.isEnabled, "enabled login item status is enabled")
check(!LaunchAtLoginStatus.disabled.isEnabled, "disabled login item status is not enabled")
check(parseTranscriptionOutput("  hello  ") == "hello", "diagnostics parser trims stdout only")

let hyperX = InputDeviceInfo(name: "HyperX QuadCast", uid: "hyperx-uid")
let macBook = InputDeviceInfo(name: "MacBook Pro Microphone", uid: "macbook-uid")
let airPods = InputDeviceInfo(name: "AirPods Pro Microphone", uid: "airpods-uid")
check(
    InputDeviceSelector.select(preference: .automatic, from: [airPods, macBook, hyperX]) == hyperX,
    "automatic microphone selection prefers HyperX"
)
check(
    InputDeviceSelector.select(preference: .automatic, from: [airPods, macBook]) == macBook,
    "automatic microphone selection falls back to MacBook microphone"
)
check(
    InputDeviceSelector.select(preference: .specific(uid: airPods.uid), from: [airPods, macBook]) == airPods,
    "specific microphone selection uses the saved device"
)
check(
    InputDeviceSelector.select(preference: .specific(uid: "disconnected"), from: [airPods, macBook]) == macBook,
    "a disconnected saved microphone falls back to the MacBook microphone"
)
check(
    InputDeviceSelector.select(preference: .automatic, from: [airPods]) == nil,
    "automatic microphone selection does not silently choose AirPods"
)
check(
    InputDevicePreference(storageValue: "device:\(hyperX.uid)").storageValue == "device:\(hyperX.uid)",
    "microphone preference round-trips through storage"
)

print("LocalDictation core checks passed")
