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
let bundledExecutable = bundleResources.appendingPathComponent("whisper-cli")
let bundledModel = bundleResources.appendingPathComponent(WhisperModelCatalog.defaultModelFilename)
let homebrewExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
let intelExecutable = URL(fileURLWithPath: "/usr/local/bin/whisper-cli")
let fallbackModel = WhisperModelCatalog.defaultModelURL(homeDirectory: resourceHome)

func resolveWith(readable: Set<URL>, bundled: URL? = bundleResources) -> TranscriptionConfiguration {
    TranscriptionResourceResolver.resolve(
        bundledResourceDirectory: bundled,
        homeDirectory: resourceHome,
        isReadable: { readable.contains($0) }
    )
}

check(
    resolveWith(readable: [bundledExecutable, homebrewExecutable, intelExecutable]).executableURL
        == bundledExecutable,
    "a bundled engine wins over every installed one"
)
// The regression this ordering exists for: a Mac carrying both Homebrew prefixes
// has the native arm64 build in /opt/homebrew and an x86_64 build in /usr/local
// that runs about ten times slower under Rosetta.
check(
    resolveWith(readable: [homebrewExecutable, intelExecutable]).executableURL == homebrewExecutable,
    "Apple-silicon Homebrew is preferred over the Intel prefix"
)
check(
    resolveWith(readable: [intelExecutable]).executableURL == intelExecutable,
    "an Intel-only install still resolves"
)
check(
    resolveWith(readable: [bundledModel, fallbackModel]).modelURL == bundledModel,
    "a bundled model wins over the downloaded one"
)
check(
    resolveWith(readable: [fallbackModel]).modelURL == fallbackModel,
    "a downloaded model resolves when nothing is bundled"
)
check(resolveWith(readable: []).language == "en", "every resolved configuration stays English")

let missingResources = resolveWith(readable: [], bundled: nil)
check(
    missingResources.executableURL == intelExecutable,
    "missing engine preserves an error path naming a real install location"
)
check(missingResources.modelURL == fallbackModel, "missing bundle preserves legacy model error path")
check(
    bundledModel.lastPathComponent == WhisperModelCatalog.defaultModelFilename,
    "bundle and fallback share one model identity"
)
_ = DictationConfiguration(transcription: missingResources)

// Shortcut storage: no saved value means the user has never configured one, so
// the defaults apply. A saved empty list is a real choice and must survive.
check(Hotkey.decodeBindings(nil) == HotkeyBinding.defaults, "an unset shortcut choice uses the defaults")
check(Hotkey.decodeBindings(Data("not json".utf8)) == HotkeyBinding.defaults, "unreadable shortcut data falls back to the defaults")
check(Hotkey.decodeBindings(Hotkey.encodeBindings([])) == [], "a saved empty shortcut list is preserved")
let savedBindings: [HotkeyBinding] = [
    .modifierTap(keyCode: 61),
    .keyCombination(keyCode: 49, modifiers: [.command, .shift], label: "Space"),
    .mouseButton(buttonNumber: 3),
]
check(Hotkey.decodeBindings(Hotkey.encodeBindings(savedBindings)) == savedBindings, "saved shortcuts round-trip")
check(
    WhisperModelCatalog.defaultModelURL(homeDirectory: URL(fileURLWithPath: "/Users/tester")).path
        == "/Users/tester/.content-agents/whisper/ggml-base.en.bin",
    "Whisper defaults to the base English model"
)
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
    deliverableTranscript(from: "[BLANK_AUDIO]") == nil,
    "a blank recording delivers nothing"
)
check(
    deliverableTranscript(from: "  [ Silence ]\n(wind blowing)\n*coughs*  ") == nil,
    "a recording of only noise delivers nothing"
)
check(
    deliverableTranscript(from: "[BLANK_AUDIO] send the file today [MUSIC]") == "send the file today",
    "sound labels are removed from around real speech"
)
check(
    deliverableTranscript(from: "call me (555) 123 4567") == "call me (555) 123 4567",
    "parentheses without a sound word are left alone"
)
check(
    deliverableTranscript(from: "ship it (finally") == "ship it (finally",
    "an unclosed bracket keeps the rest of the sentence"
)
check(
    deliverableTranscript(from: "  hello   there  ") == "hello there",
    "spacing is tidied the way it always was"
)
check(
    DictationState.transcribing.canTransition(to: .idle),
    "a silent recording may end without an insertion"
)

let historyStart = Date(timeIntervalSince1970: 0)
var history = TranscriptHistory.appending("first", to: [], date: historyStart)
history = TranscriptHistory.appending("second", to: history, date: historyStart)
check(history.map(\.text) == ["second", "first"], "history keeps the newest transcript first")
check(
    TranscriptHistory.appending("   ", to: history, date: historyStart).count == 2,
    "history ignores a blank transcript"
)
check(
    TranscriptHistory.appending("second", to: history, date: historyStart).map(\.text) == ["second", "first"],
    "history collapses an immediate repeat"
)
var capped: [TranscriptHistoryEntry] = []
for index in 0..<(TranscriptHistory.limit + 5) {
    capped = TranscriptHistory.appending("entry \(index)", to: capped, date: historyStart)
}
check(capped.count == TranscriptHistory.limit, "history stops at the limit")
check(capped.first?.text == "entry \(TranscriptHistory.limit + 4)", "history drops the oldest entry first")
check(
    TranscriptHistoryEntry(text: "one\ntwo\tthree", date: historyStart).menuTitle() == "one two three",
    "history preview collapses newlines onto one line"
)
check(
    TranscriptHistoryEntry(text: String(repeating: "a", count: 80), date: historyStart)
        .menuTitle(limit: 10) == String(repeating: "a", count: 10) + "\u{2026}",
    "history preview truncates a long transcript"
)
check(
    DictationMenuCommand(state: .recording) == DictationMenuCommand(title: "Stop Dictation", isEnabled: true),
    "recording offers a stop command in the menu"
)
check(
    DictationMenuCommand(state: .idle) == DictationMenuCommand(title: "Start Dictation", isEnabled: true),
    "idle offers a start command in the menu"
)
check(
    !DictationMenuCommand(state: .transcribing).isEnabled,
    "transcribing disables the menu command"
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
// Matching: a modifier tap fires on the press with no other modifier held, a key
// combination needs exactly its own modifiers, and only listed shortcuts count.
let rightOption: [HotkeyBinding] = [.modifierTap(keyCode: 61)]
check(
    Hotkey.matchesToggle(.flagsChanged(keyCode: 61, modifiers: .option), bindings: rightOption),
    "right Option matches"
)
check(
    !Hotkey.matchesToggle(.flagsChanged(keyCode: 58, modifiers: .option), bindings: rightOption),
    "left Option does not match"
)
check(
    !Hotkey.matchesToggle(.flagsChanged(keyCode: 61, modifiers: []), bindings: rightOption),
    "releasing right Option does not match"
)
check(
    !Hotkey.matchesToggle(.flagsChanged(keyCode: 61, modifiers: [.option, .command]), bindings: rightOption),
    "right Option held with Command does not match"
)

let commandShiftSpace: [HotkeyBinding] = [
    .keyCombination(keyCode: 49, modifiers: [.command, .shift], label: "Space"),
]
check(
    Hotkey.matchesToggle(.keyDown(keyCode: 49, modifiers: [.command, .shift], isRepeat: false), bindings: commandShiftSpace),
    "a saved key combination matches"
)
check(
    !Hotkey.matchesToggle(.keyDown(keyCode: 49, modifiers: [.command, .shift], isRepeat: true), bindings: commandShiftSpace),
    "a key repeat does not match"
)
check(
    !Hotkey.matchesToggle(.keyDown(keyCode: 49, modifiers: [.command, .shift, .control], isRepeat: false), bindings: commandShiftSpace),
    "an extra modifier does not match"
)
check(commandShiftSpace[0].systemHotKey?.keyCode == 49, "a key combination can be registered as a system hot key")
check(HotkeyBinding.modifierTap(keyCode: 61).systemHotKey == nil, "a modifier tap cannot be a system hot key")
check(HotkeyBinding.modifierTap(keyCode: 61).displayName == "Right Option", "a modifier tap prints its key name")
check(commandShiftSpace[0].displayName == "\u{21E7}\u{2318}Space", "a key combination prints its modifier symbols")

let middleMouse: [HotkeyBinding] = [.mouseButton(buttonNumber: 2)]
check(Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2), bindings: middleMouse), "middle mouse button matches")
check(!Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 3), bindings: middleMouse), "a different mouse button does not match")
check(!Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2), bindings: rightOption), "an unlisted shortcut is ignored")
check(!Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2), bindings: []), "no shortcuts means nothing matches")

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
