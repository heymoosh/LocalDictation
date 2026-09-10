import AVFoundation
import LocalDictationCore

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let inputDeviceManager: AudioInputDeviceManager
    private var audioFile: AVAudioFile?
    private var audioURL: URL?

    init(inputDeviceManager: AudioInputDeviceManager = AudioInputDeviceManager()) {
        self.inputDeviceManager = inputDeviceManager
    }

    @discardableResult
    func start(preference: InputDevicePreference = .automatic) throws -> InputDeviceInfo {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw RecorderError.microphonePermission
        }
        let input = engine.inputNode
        let selectedDevice = try inputDeviceManager.configure(input, preference: preference)
        let format = input.inputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).wav")
        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        audioURL = url
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            do { try self?.audioFile?.write(from: buffer) }
            catch { NSLog("Local Dictation audio write failed: %@", error.localizedDescription) }
        }
        engine.prepare()
        try engine.start()
        return selectedDevice
    }

    func stop() throws -> URL {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        guard let audioURL else { throw RecorderError.noRecording }
        self.audioURL = nil
        return audioURL
    }
}

private enum RecorderError: LocalizedError {
    case noRecording
    case microphonePermission

    var errorDescription: String? {
        switch self {
        case .noRecording:
            return "There is no active recording."
        case .microphonePermission:
            return "Microphone access is not enabled. Allow LocalDictation in System Settings, then relaunch it."
        }
    }
}
