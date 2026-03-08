import Foundation
import os

/// Persistent transcription history with auto-purge.
///
/// Stored at ~/.config/parkeet/history.json (matching Python version).
@Observable
final class HistoryStore {

    private(set) var entries: [HistoryEntry] = []
    private let log = Logger(subsystem: "com.parkeet.app", category: "HistoryStore")

    private var retentionHours: Double = 48.0
    private var storageURL: URL {
        Self.historyFileURL()
    }

    init() {
        Self.migrateIfNeeded(to: storageURL)
        load()
    }

    /// Sandbox-compatible history file location in Application Support.
    private static func historyFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let parkeetDir = appSupport.appendingPathComponent("Parkeet")
        try? FileManager.default.createDirectory(at: parkeetDir, withIntermediateDirectories: true)
        return parkeetDir.appendingPathComponent("history.json")
    }

    /// Migrate history from the old ~/.config/parkeet/ location (pre-sandbox).
    private static func migrateIfNeeded(to newURL: URL) {
        let oldPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parkeet/history.json")
        if FileManager.default.fileExists(atPath: oldPath.path),
           !FileManager.default.fileExists(atPath: newURL.path) {
            try? FileManager.default.copyItem(at: oldPath, to: newURL)
        }
    }

    // MARK: - CRUD

    func add(entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        purgeOld()
        save()
        log.info("History entry added: \(entry.type.rawValue), \(entry.wordCount) words")
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
        log.info("History cleared")
    }

    func updateRetention(hours: Double) {
        retentionHours = hours
        purgeOld()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let container = try JSONDecoder().decode(HistoryContainer.self, from: data)
            entries = container.entries
            purgeOld()
            log.info("Loaded \(self.entries.count) history entries")
        } catch {
            log.error("Failed to load history: \(error)")
            log.error("Removing incompatible history file")
            try? FileManager.default.removeItem(at: storageURL)
            entries = []
        }
    }

    private func save() {
        do {
            let container = HistoryContainer(version: 1, entries: entries)
            let data = try JSONEncoder().encode(container)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            log.error("Failed to save history: \(error)")
        }
    }

    private func purgeOld() {
        let cutoff = Date().addingTimeInterval(-retentionHours * 3600)
        let before = entries.count
        entries.removeAll { $0.timestamp < cutoff }
        let purged = before - entries.count
        if purged > 0 {
            log.info("Purged \(purged) old history entries")
        }
    }
}

// MARK: - Data Types

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let type: EntryType
    let text: String
    let wordCount: Int
    let sourceFilename: String?
    let outputPath: String?

    enum EntryType: String, Codable {
        case hotkey
        case file
        case meeting
    }

    init(
        type: EntryType,
        text: String,
        wordCount: Int,
        sourceFilename: String? = nil,
        outputPath: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.text = text
        self.wordCount = wordCount
        self.sourceFilename = sourceFilename
        self.outputPath = outputPath
    }
}

private struct HistoryContainer: Codable {
    let version: Int
    let entries: [HistoryEntry]
}
