import Foundation
import LocalDictationCore

final class LocalCommandTranscriber {
    static func defaultConfiguration(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> TranscriptionConfiguration {
        TranscriptionResourceResolver.resolve(
            bundledResourceDirectory: bundle.resourceURL,
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            isReadable: { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
                    && fileManager.isReadableFile(atPath: url.path)
            }
        )
    }

    /// A fifth of a second of 16 kHz mono silence, written by hand so the warm-up
    /// run needs no audio engine and no bundled fixture.
    static func writeSilentWarmUpAudio() throws -> URL {
        let sampleRate: UInt32 = 16_000
        let sampleCount = Int(sampleRate) / 5
        let dataBytes = UInt32(sampleCount * 2)
        var wav = Data()
        func append(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(dataBytes)
        wav.append(Data(count: sampleCount * 2))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-warmup-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }

    func transcribe(audioURL: URL, configuration: TranscriptionConfiguration) throws -> String {
        guard FileManager.default.isReadableFile(atPath: configuration.executableURL.path) else {
            throw TranscriberError.missingExecutable(configuration.executableURL.path)
        }
        guard FileManager.default.isReadableFile(atPath: configuration.modelURL.path) else {
            throw TranscriberError.missingModel(configuration.modelURL.path)
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments(for: audioURL)
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let result = parseTranscriptionOutput(String(data: outputData, encoding: .utf8) ?? "")
        guard process.terminationStatus == 0 else {
            let diagnostics = String(data: errorData, encoding: .utf8) ?? ""
            throw TranscriberError.commandFailed(diagnostics.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}

private enum TranscriberError: LocalizedError {
    case missingExecutable(String)
    case missingModel(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path): return "Whisper executable not found at \(path)."
        case .missingModel(let path): return "Whisper model not found at \(path)."
        case .commandFailed(let output): return output.isEmpty ? "Whisper exited with an error." : output
        }
    }
}
