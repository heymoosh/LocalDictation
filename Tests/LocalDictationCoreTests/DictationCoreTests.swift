import XCTest
@testable import LocalDictationCore

final class DictationCoreTests: XCTestCase {
    func testResourcePrecedenceIndependentlyForExecutableAndModel() {
        let home = URL(fileURLWithPath: "/Users/resolver-test")
        let resources = URL(fileURLWithPath: "/Fixture.app/Contents/Resources")
        let explicitExecutable = URL(fileURLWithPath: "/chosen/whisper-cli")
        let explicitModel = URL(fileURLWithPath: "/chosen/ggml-base.en.bin")
        let bundledExecutable = resources.appendingPathComponent("whisper-cli")
        let bundledModel = resources.appendingPathComponent("ggml-tiny.en.bin")
        let fallbackExecutable = URL(fileURLWithPath: "/usr/local/bin/whisper-cli")
        let fallbackModel = WhisperModelCatalog.defaultModelURL(homeDirectory: home)
        let cases: [(hasExplicit: Bool, explicitReadable: Bool, bundleReadable: Bool)] = [
            (true, true, true), (true, false, true), (false, false, true),
            (true, false, false), (false, false, false)
        ]
        // Exercise all 25 mixed combinations without touching the filesystem.
        for executableCase in cases {
            for modelCase in cases {
                var readable = Set([fallbackExecutable, fallbackModel])
                if executableCase.explicitReadable { readable.insert(explicitExecutable) }
                if executableCase.bundleReadable { readable.insert(bundledExecutable) }
                if modelCase.explicitReadable { readable.insert(explicitModel) }
                if modelCase.bundleReadable { readable.insert(bundledModel) }
                var probes: [URL] = []
                let resolved = TranscriptionResourceResolver.resolve(
                    explicitExecutableURL: executableCase.hasExplicit ? explicitExecutable : nil,
                    explicitModelURL: modelCase.hasExplicit ? explicitModel : nil,
                    bundledResourceDirectory: resources,
                    homeDirectory: home,
                    isReadable: { url in
                        probes.append(url)
                        return readable.contains(url)
                    }
                )
                XCTAssertEqual(resolved.executableURL, executableCase.explicitReadable ? explicitExecutable
                    : executableCase.bundleReadable ? bundledExecutable : fallbackExecutable)
                XCTAssertEqual(resolved.modelURL, modelCase.explicitReadable ? explicitModel
                    : modelCase.bundleReadable ? bundledModel : fallbackModel)
                XCTAssertEqual(resolved.language, "en")
                var expectedProbes: [URL] = []
                if executableCase.hasExplicit { expectedProbes.append(explicitExecutable) }
                if !executableCase.explicitReadable { expectedProbes.append(bundledExecutable) }
                if modelCase.hasExplicit { expectedProbes.append(explicitModel) }
                if !modelCase.explicitReadable { expectedProbes.append(bundledModel) }
                XCTAssertEqual(probes, expectedProbes)
            }
        }
    }

    func testAbsentBundleRetainsLegacyPathsEvenWhenResourcesAreMissing() {
        let resolved = TranscriptionResourceResolver.resolve(
            bundledResourceDirectory: nil,
            homeDirectory: URL(fileURLWithPath: "/Users/resolver-test"),
            isReadable: { _ in false }
        )
        XCTAssertEqual(resolved.executableURL.path, "/usr/local/bin/whisper-cli")
        XCTAssertEqual(resolved.modelURL.path, "/Users/resolver-test/.content-agents/whisper/ggml-tiny.en.bin")
        XCTAssertEqual(WhisperModelCatalog.defaultModelFilename, "ggml-tiny.en.bin")
        XCTAssertEqual(resolved.language, "en")
        let coreOnly = DictationConfiguration(transcription: resolved)
        XCTAssertFalse(coreOnly.cleanupEnabled)
        XCTAssertNil(coreOnly.cleanupCommand)
    }

    func testWhisperModelDefaultsToTinyEnglishInContentAgentsDirectory() {
        let homeDirectory = URL(fileURLWithPath: "/Users/tester")

        XCTAssertEqual(
            WhisperModelCatalog.defaultModelURL(homeDirectory: homeDirectory).path,
            "/Users/tester/.content-agents/whisper/ggml-tiny.en.bin"
        )
        XCTAssertEqual(WhisperModelCatalog.displayName(for: "ggml-tiny.en.bin"), "tiny.en")
    }

    func testWhisperModelCatalogRecognizesOnlyGGMLBinModels() {
        XCTAssertTrue(WhisperModelCatalog.isModelFilename("ggml-base.en.bin"))
        XCTAssertTrue(WhisperModelCatalog.isModelFilename("ggml-tiny.en-q5_1.bin"))
        XCTAssertFalse(WhisperModelCatalog.isModelFilename("ggml-tiny.en.gguf"))
        XCTAssertFalse(WhisperModelCatalog.isModelFilename("notes.bin"))
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

    func testRightOptionIsTheToggleKey() {
        XCTAssertTrue(
            Hotkey.matchesRightOptionPress(
                keyCode: 61,
                optionIsDown: true,
                controlIsDown: false,
                commandIsDown: false
            )
        )
        XCTAssertFalse(
            Hotkey.matchesRightOptionPress(
                keyCode: 61,
                optionIsDown: false,
                controlIsDown: false,
                commandIsDown: false
            )
        )
        XCTAssertFalse(
            Hotkey.matchesRightOptionPress(
                keyCode: 58,
                optionIsDown: true,
                controlIsDown: false,
                commandIsDown: false
            )
        )
        XCTAssertFalse(
            Hotkey.matchesRightOptionPress(
                keyCode: 61,
                optionIsDown: true,
                controlIsDown: true,
                commandIsDown: false
            )
        )
    }

    func testGlobalHotkeyEventClassificationCoversRequestedInputs() {
        XCTAssertTrue(
            Hotkey.matchesToggle(
                .flagsChanged(
                    keyCode: 61,
                    optionIsDown: true,
                    controlIsDown: false,
                    commandIsDown: false
                )
            )
        )
        XCTAssertTrue(Hotkey.matchesToggle(.otherMouseDown(buttonNumber: 2)))
        XCTAssertFalse(Hotkey.matchesToggle(.flagsChanged(
            keyCode: 61,
            optionIsDown: false,
            controlIsDown: false,
            commandIsDown: false
        )))
    }

    func testTranscriptionOutputDoesNotAddDiagnostics() {
        XCTAssertEqual(parseTranscriptionOutput("Testing one, two, three.\n"), "Testing one, two, three.")
        XCTAssertEqual(parseTranscriptionOutput("  hello  "), "hello")
    }

    func testFallbackShortcutIsControlOptionSpace() {
        XCTAssertTrue(Hotkey.matchesFallback(keyCode: 49, controlIsDown: true, optionIsDown: true, isRepeat: false))
        XCTAssertFalse(Hotkey.matchesFallback(keyCode: 49, controlIsDown: false, optionIsDown: true, isRepeat: false))
        XCTAssertFalse(Hotkey.matchesFallback(keyCode: 49, controlIsDown: true, optionIsDown: true, isRepeat: true))
    }

    func testMiddleMouseButtonIsTheToggleButton() {
        XCTAssertTrue(Hotkey.matchesMiddleMouseButton(buttonNumber: 2))
        XCTAssertFalse(Hotkey.matchesMiddleMouseButton(buttonNumber: 0))
        XCTAssertFalse(Hotkey.matchesMiddleMouseButton(buttonNumber: 1))
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
