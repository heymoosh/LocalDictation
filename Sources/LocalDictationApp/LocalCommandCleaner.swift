import Foundation

final class LocalCommandCleaner {
    func clean(_ text: String) throws -> String {
        let executable = UserDefaults.standard.string(forKey: "cleanupExecutable") ?? "/usr/local/bin/ollama"
        let model = UserDefaults.standard.string(forKey: "cleanupModel") ?? "llama3.2:latest"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CleanupError.missingExecutable(executable)
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["run", model, "Return only the corrected text. Preserve meaning and do not add commentary.\n\n" + text]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let result = String(data: data, encoding: .utf8),
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CleanupError.commandFailed
        }
        return result
    }
}

private enum CleanupError: LocalizedError {
    case missingExecutable(String)
    case commandFailed

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path): return "Cleanup executable not found at \(path)."
        case .commandFailed: return "Local cleanup failed. The raw transcript was used."
        }
    }
}
