import XCTest
@testable import LocalDictationCore

final class DictationCoreTests: XCTestCase {
    private func resolve(readable: Set<URL>, bundled: URL?) -> TranscriptionConfiguration {
        TranscriptionResourceResolver.resolve(
            bundledResourceDirectory: bundled,
            homeDirectory: URL(fileURLWithPath: "/Users/resolver-test"),
            isReadable: { readable.contains($0) }
        )
    }

    func testBundledResourcesWinOverEveryInstallLocation() {
        let bundle = URL(fileURLWithPath: "/Fixture.app/Contents/Resources")
        let bundledExecutable = bundle.appendingPathComponent("whisper-cli")
        let bundledModel = bundle.appendingPathComponent(WhisperModelCatalog.defaultModelFilename)
        let resolved = resolve(
            readable: [
                bundledExecutable,
                bundledModel,
                URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
                URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
            ],
            bundled: bundle
        )

        XCTAssertEqual(resolved.executableURL, bundledExecutable)
        XCTAssertEqual(resolved.modelURL, bundledModel)
    }

    /// A Mac with both Homebrew prefixes has the native arm64 engine in
    /// /opt/homebrew and an x86_64 engine in /usr/local that runs about ten times
    /// slower under Rosetta, so the order between them is a performance contract.
    func testAppleSiliconHomebrewIsPreferredOverTheIntelPrefix() {
        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
        let intel = URL(fileURLWithPath: "/usr/local/bin/whisper-cli")

        XCTAssertEqual(resolve(readable: [homebrew, intel], bundled: nil).executableURL, homebrew)
        XCTAssertEqual(resolve(readable: [intel], bundled: nil).executableURL, intel)
    }

    func testAbsentBundleRetainsLegacyPathsEvenWhenResourcesAreMissing() {
        let resolved = resolve(readable: [], bundled: nil)

        XCTAssertEqual(resolved.executableURL.path, "/usr/local/bin/whisper-cli")
        XCTAssertEqual(resolved.modelURL.path, "/Users/resolver-test/.content-agents/whisper/ggml-base.en.bin")
        XCTAssertEqual(WhisperModelCatalog.defaultModelFilename, "ggml-base.en.bin")
        XCTAssertEqual(resolved.language, "en")
    }

    func testWhisperModelDefaultsToBaseEnglishInContentAgentsDirectory() {
        XCTAssertEqual(
            WhisperModelCatalog.defaultModelURL(homeDirectory: URL(fileURLWithPath: "/Users/tester")).path,
            "/Users/tester/.content-agents/whisper/ggml-base.en.bin"
        )
    }

    func testUnsetShortcutsUseTheDefaultsAndAnEmptyChoiceIsKept() {
        XCTAssertEqual(Hotkey.decodeBindings(nil), HotkeyBinding.defaults)
        XCTAssertEqual(Hotkey.decodeBindings(Data("not json".utf8)), HotkeyBinding.defaults)
        XCTAssertEqual(Hotkey.decodeBindings(Hotkey.encodeBindings([])), [])
    }

    func testSavedShortcutsRoundTripThroughStorage() {
        let bindings: [HotkeyBinding] = [
            .modifierTap(keyCode: 61),
            .keyCombination(keyCode: 49, modifiers: [.command, .shift], label: "Space"),
            .mouseButton(buttonNumber: 3),
        ]

        XCTAssertEqual(Hotkey.decodeBindings(Hotkey.encodeBindings(bindings)), bindings)
    }

    func testUnlistedShortcutsDoNotToggleDictation() {
        let rightOption: [HotkeyBinding] = [.modifierTap(keyCode: 61)]

        XCTAssertFalse(Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2), bindings: rightOption))
        XCTAssertFalse(Hotkey.matchesToggle(
            .keyDown(keyCode: 49, modifiers: [.control, .option], isRepeat: false),
            bindings: rightOption
        ))
        XCTAssertFalse(Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2), bindings: []))
    }

    func testWhisperCommandUsesConfiguredModelAndWav() {
        let config = TranscriptionConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
            modelURL: URL(fileURLWithPath: "/tmp/base.en.bin")
        )
        let audioURL = URL(fileURLWithPath: "/tmp/dictation.wav")

        XCTAssertEqual(
            config.arguments(for: audioURL),
            ["-m", "/tmp/base.en.bin", "-l", "en", "-nt", "-np", "/tmp/dictation.wav"]
        )
    }

    func testTranscriptTextIsNormalizedForInsertion() {
        XCTAssertEqual(normalizeTranscript("  hello\nworld  "), "hello world")
        XCTAssertEqual(normalizeTranscript(""), "")
    }

    func testStateMachineAllowsOnlyValidTransitions() {
        XCTAssertTrue(DictationState.idle.canTransition(to: .recording))
        XCTAssertTrue(DictationState.recording.canTransition(to: .transcribing))
        XCTAssertTrue(DictationState.transcribing.canTransition(to: .inserting))
        XCTAssertTrue(DictationState.inserting.canTransition(to: .idle))
        XCTAssertFalse(DictationState.idle.canTransition(to: .inserting))
    }

    func testIndicatorPresentationCoversRecordingAndProcessingStates() {
        XCTAssertEqual(
            DictationIndicatorPresentation(state: .idle),
            DictationIndicatorPresentation(
                kind: .ready,
                title: "Ready",
                accessibilityLabel: "Local Dictation is ready"
            )
        )
        XCTAssertEqual(
            DictationIndicatorPresentation(state: .recording),
            DictationIndicatorPresentation(
                kind: .recording,
                title: "Recording",
                accessibilityLabel: "Local Dictation is recording"
            )
        )
        XCTAssertEqual(
            DictationIndicatorPresentation(state: .transcribing),
            DictationIndicatorPresentation(
                kind: .processing,
                title: "Processing",
                accessibilityLabel: "Local Dictation is processing the transcription"
            )
        )
        XCTAssertEqual(
            DictationIndicatorPresentation(state: .inserting),
            DictationIndicatorPresentation(
                kind: .processing,
                title: "Processing",
                accessibilityLabel: "Local Dictation is processing the transcription"
            )
        )
    }

    func testSilentRecordingHasNothingToDeliver() {
        XCTAssertNil(deliverableTranscript(from: "[BLANK_AUDIO]"))
        XCTAssertNil(deliverableTranscript(from: "  [ Silence ]\n(wind blowing)\n*coughs*  "))
        XCTAssertTrue(DictationState.transcribing.canTransition(to: .idle))
    }

    func testSoundLabelsAreStrippedWithoutLosingSpeech() {
        XCTAssertEqual(
            deliverableTranscript(from: "[BLANK_AUDIO] send the file today [MUSIC]"),
            "send the file today"
        )
        XCTAssertEqual(
            deliverableTranscript(from: "call me (555) 123 4567"),
            "call me (555) 123 4567"
        )
        XCTAssertEqual(deliverableTranscript(from: "ship it (finally"), "ship it (finally")
        XCTAssertEqual(deliverableTranscript(from: "  hello   there  "), "hello there")
    }

    func testTranscriptHistoryKeepsNewestEntriesUpToTheLimit() {
        let date = Date(timeIntervalSince1970: 0)
        var history = TranscriptHistory.appending("first", to: [], date: date)
        history = TranscriptHistory.appending("second", to: history, date: date)
        XCTAssertEqual(history.map(\.text), ["second", "first"])

        XCTAssertEqual(TranscriptHistory.appending("  \n ", to: history, date: date), history)
        XCTAssertEqual(TranscriptHistory.appending("second", to: history, date: date), history)

        var capped: [TranscriptHistoryEntry] = []
        for index in 0..<(TranscriptHistory.limit + 5) {
            capped = TranscriptHistory.appending("entry \(index)", to: capped, date: date)
        }
        XCTAssertEqual(capped.count, TranscriptHistory.limit)
        XCTAssertEqual(capped.first?.text, "entry \(TranscriptHistory.limit + 4)")
    }

    func testTranscriptHistoryPreviewIsOneShortLine() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            TranscriptHistoryEntry(text: "one\ntwo\tthree", date: date).menuTitle(),
            "one two three"
        )
        XCTAssertEqual(
            TranscriptHistoryEntry(text: String(repeating: "a", count: 80), date: date).menuTitle(limit: 10),
            String(repeating: "a", count: 10) + "\u{2026}"
        )
    }

    func testMenuCommandOffersStopWhileRecording() {
        XCTAssertEqual(
            DictationMenuCommand(state: .idle),
            DictationMenuCommand(title: "Start Dictation", isEnabled: true)
        )
        XCTAssertEqual(
            DictationMenuCommand(state: .failed),
            DictationMenuCommand(title: "Start Dictation", isEnabled: true)
        )
        XCTAssertEqual(
            DictationMenuCommand(state: .recording),
            DictationMenuCommand(title: "Stop Dictation", isEnabled: true)
        )
        XCTAssertEqual(
            DictationMenuCommand(state: .transcribing),
            DictationMenuCommand(title: "Transcribing\u{2026}", isEnabled: false)
        )
        XCTAssertEqual(
            DictationMenuCommand(state: .inserting),
            DictationMenuCommand(title: "Inserting Text\u{2026}", isEnabled: false)
        )
    }

    func testIndicatorLayoutIsCompactExceptWhileRecording() {
        XCTAssertEqual(
            DictationIndicatorLayout.size(for: .idle),
            DictationIndicatorSize(width: 32, height: 32)
        )
        XCTAssertEqual(
            DictationIndicatorLayout.size(for: .recording),
            DictationIndicatorSize(width: 32, height: 128)
        )
        XCTAssertEqual(
            DictationIndicatorLayout.size(for: .transcribing),
            DictationIndicatorSize(width: 32, height: 32)
        )
    }

    func testPersistedIndicatorFrameIsNormalizedToCompactSize() {
        let persistedFrame = DictationIndicatorFrame(
            originX: 1874,
            originY: 536,
            width: 32,
            height: 128
        )

        let compactFrame = DictationIndicatorLayout.compactFrame(from: persistedFrame)

        XCTAssertEqual(compactFrame, DictationIndicatorFrame(
            originX: 1874,
            originY: 632,
            width: 32,
            height: 32
        ))
        XCTAssertEqual(compactFrame.maxX, persistedFrame.maxX)
        XCTAssertEqual(compactFrame.maxY, persistedFrame.maxY)
    }

    func testAModifierTapMatchesOnlyItsOwnPress() {
        let rightOption: [HotkeyBinding] = [.modifierTap(keyCode: 61)]

        XCTAssertTrue(Hotkey.matchesToggle(.flagsChanged(keyCode: 61, modifiers: .option), bindings: rightOption))
        // Releasing the key reports no modifiers, so only the press fires.
        XCTAssertFalse(Hotkey.matchesToggle(.flagsChanged(keyCode: 61, modifiers: []), bindings: rightOption))
        XCTAssertFalse(Hotkey.matchesToggle(.flagsChanged(keyCode: 58, modifiers: .option), bindings: rightOption))
        XCTAssertFalse(Hotkey.matchesToggle(
            .flagsChanged(keyCode: 61, modifiers: [.option, .control]),
            bindings: rightOption
        ))
    }

    func testAKeyCombinationNeedsExactlyItsOwnModifiers() {
        let bindings: [HotkeyBinding] = [
            .keyCombination(keyCode: 49, modifiers: [.command, .shift], label: "Space"),
        ]

        XCTAssertTrue(Hotkey.matchesToggle(
            .keyDown(keyCode: 49, modifiers: [.command, .shift], isRepeat: false),
            bindings: bindings
        ))
        XCTAssertFalse(Hotkey.matchesToggle(
            .keyDown(keyCode: 49, modifiers: [.command, .shift], isRepeat: true),
            bindings: bindings
        ))
        XCTAssertFalse(Hotkey.matchesToggle(
            .keyDown(keyCode: 49, modifiers: [.command, .shift, .option], isRepeat: false),
            bindings: bindings
        ))
    }

    func testOnlyKeyCombinationsCanBeSystemHotKeys() {
        let combination = HotkeyBinding.keyCombination(keyCode: 49, modifiers: [.command, .shift], label: "Space")

        XCTAssertEqual(combination.systemHotKey?.keyCode, 49)
        XCTAssertEqual(combination.systemHotKey?.modifiers, [.command, .shift])
        XCTAssertNil(HotkeyBinding.modifierTap(keyCode: 61).systemHotKey)
        XCTAssertNil(HotkeyBinding.mouseButton(buttonNumber: 2).systemHotKey)
    }

    func testShortcutsPrintReadableNames() {
        XCTAssertEqual(HotkeyBinding.modifierTap(keyCode: 61).displayName, "Right Option")
        XCTAssertEqual(
            HotkeyBinding.keyCombination(keyCode: 49, modifiers: [.command, .shift], label: "Space").displayName,
            "\u{21E7}\u{2318}Space"
        )
        XCTAssertEqual(HotkeyBinding.mouseButton(buttonNumber: 2).displayName, "Middle mouse button")
        XCTAssertEqual(HotkeyBinding.mouseButton(buttonNumber: 3).displayName, "Mouse button 4")
    }

    func testTranscriptionOutputDoesNotAddDiagnostics() {
        XCTAssertEqual(parseTranscriptionOutput("Testing one, two, three.\n"), "Testing one, two, three.")
        XCTAssertEqual(parseTranscriptionOutput("  hello  "), "hello")
    }

    func testAMouseButtonMatchesOnlyThatButton() {
        let middleMouse: [HotkeyBinding] = [.mouseButton(buttonNumber: 2)]

        XCTAssertTrue(Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2), bindings: middleMouse))
        XCTAssertFalse(Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 3), bindings: middleMouse))
    }

    func testTranscriptDeliveryKeepsClipboardAndAutomaticallyPastes() {
        let delivery = TranscriptDelivery(text: "hello world")

        XCTAssertEqual(delivery.text, "hello world")
        XCTAssertTrue(delivery.keepsTranscriptOnClipboard)
        XCTAssertTrue(delivery.automaticallyPastes)
    }

    func testPasteAutomationRequiresAccessibilityOnly() {
        XCTAssertTrue(PasteAutomationAccess(accessibilityTrusted: true).canPaste)
        XCTAssertFalse(PasteAutomationAccess(accessibilityTrusted: false).canPaste)
    }

    func testLaunchAtLoginStatusOnlyMarksEnabledAsEnabled() {
        XCTAssertTrue(LaunchAtLoginStatus.enabled.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.disabled.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.requiresApproval.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.unavailable.isEnabled)
    }

    func testAutomaticMicrophoneSelectionPrefersHyperXThenMacBook() {
        let hyperX = InputDeviceInfo(name: "HyperX QuadCast", uid: "hyperx-uid")
        let macBook = InputDeviceInfo(name: "MacBook Pro Microphone", uid: "macbook-uid")
        let airPods = InputDeviceInfo(name: "AirPods Pro Microphone", uid: "airpods-uid")

        XCTAssertEqual(
            InputDeviceSelector.select(preference: .automatic, from: [airPods, macBook, hyperX]),
            hyperX
        )
        XCTAssertEqual(
            InputDeviceSelector.select(preference: .automatic, from: [airPods, macBook]),
            macBook
        )
        XCTAssertNil(InputDeviceSelector.select(preference: .automatic, from: [airPods]))
    }

    func testSpecificMicrophoneSelectionAndStorageRoundTrip() {
        let airPods = InputDeviceInfo(name: "AirPods Pro Microphone", uid: "airpods-uid")
        let macBook = InputDeviceInfo(name: "MacBook Pro Microphone", uid: "macbook-uid")
        let preference = InputDevicePreference.specific(uid: airPods.uid)

        XCTAssertEqual(InputDeviceSelector.select(preference: preference, from: [airPods, macBook]), airPods)
        XCTAssertEqual(InputDevicePreference(storageValue: preference.storageValue), preference)
        XCTAssertEqual(
            InputDeviceSelector.select(
                preference: .specific(uid: "disconnected"),
                from: [airPods, macBook]
            ),
            macBook
        )
    }

}
