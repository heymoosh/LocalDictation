import Foundation
import LocalDictationCore

final class LocalCommandTranscriber {
    static func defaultConfiguration(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> TranscriptionConfiguration {
        func explicitURL(forKey key: String) -> URL? {
            guard let path = defaults.string(forKey: key), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        return TranscriptionResourceResolver.resolve(
            explicitExecutableURL: explicitURL(forKey: "transcriptionExecutable"),
            explicitModelURL: explicitURL(forKey: "transcriptionModel"),
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
