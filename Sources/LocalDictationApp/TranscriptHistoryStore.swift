import Foundation
import LocalDictationCore

/// Keeps the recent transcripts on disk so they survive a quit. Everything a
/// user dictates is theirs alone, so the file lives in this app's own
/// Application Support folder and is written owner-readable only; nothing is
/// sent anywhere and "Clear History" deletes the file outright.
final class TranscriptHistoryStore {
    private let fileURL: URL?
    private var entries: [TranscriptHistoryEntry]

    init() {
        fileURL = TranscriptHistoryStore.defaultFileURL()
        entries = TranscriptHistoryStore.load(from: fileURL)
    }

    var recent: [TranscriptHistoryEntry] { entries }

    func record(_ text: String, date: Date = Date()) {
        let updated = TranscriptHistory.appending(text, to: entries, date: date)
        guard updated != entries else { return }
        entries = updated
        persist()
    }

    func clear() {
        entries = []
        guard let fileURL else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Already gone; clearing an empty history is not a failure.
        } catch {
            NSLog("Local Dictation: could not delete the transcript history: \(error.localizedDescription)")
        }
    }

    private static func defaultFileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            NSLog("Local Dictation: no Application Support directory; history will not persist.")
            return nil
        }
        return support
            .appendingPathComponent("LocalDictation", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    private static func load(from fileURL: URL?) -> [TranscriptHistoryEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([TranscriptHistoryEntry].self, from: data) else {
            // A truncated or hand-edited file should cost the user their history,
            // not the ability to dictate. Start over rather than refuse to launch.
            NSLog("Local Dictation: transcript history was unreadable and will be rebuilt.")
            return []
        }
        return Array(decoded.prefix(TranscriptHistory.limit))
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Local Dictation: could not save the transcript history: \(error.localizedDescription)")
        }
    }
}
