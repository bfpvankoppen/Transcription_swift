import Foundation
import os

/// Persistent transcription history with auto-purge.
///
/// Stored at ~/.config/parkeet/history.json (matching Python version).
@Observable
final class HistoryStore {

    private(set) var entries: [HistoryEntry] = []
    private let log = Logger(subsystem: "com.praten.app", category: "HistoryStore")

    private var retentionHours: Double = 48.0
    private(set) var embeddings: [UUID: [String: Float]] = [:]
    var embeddingEngine: EmbeddingEngine?

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
        let pratenDir = appSupport.appendingPathComponent("Praten")
        try? FileManager.default.createDirectory(at: pratenDir, withIntermediateDirectories: true)
        return pratenDir.appendingPathComponent("history.json")
    }

    /// Migrate history from old locations (pre-rename "Parkeet" dir, pre-sandbox ~/.config/).
    private static func migrateIfNeeded(to newURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newURL.path) else { return }

        // 1. Migrate from old "Parkeet" Application Support directory
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldAppSupportPath = appSupport.appendingPathComponent("Parkeet/history.json")
        if fm.fileExists(atPath: oldAppSupportPath.path) {
            try? fm.copyItem(at: oldAppSupportPath, to: newURL)
            return
        }

        // 2. Migrate from pre-sandbox ~/.config/parkeet/ location
        let oldConfigPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parkeet/history.json")
        if fm.fileExists(atPath: oldConfigPath.path) {
            try? fm.copyItem(at: oldConfigPath, to: newURL)
        }
    }

    // MARK: - CRUD

    func add(entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        purgeOld()
        save()
        log.info("History entry added: \(entry.type.rawValue), \(entry.wordCount) words")
        if let engine = embeddingEngine {
            embeddings[entry.id] = engine.embed(entry.text)
        }
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        embeddings.removeValue(forKey: id)
        save()
    }

    func clear() {
        entries.removeAll()
        embeddings.removeAll()
        save()
        log.info("History cleared")
    }

    func updateRetention(hours: Double) {
        retentionHours = hours
        purgeOld()
        save()
    }

    func rebuildEmbeddings() {
        guard let engine = embeddingEngine else { return }
        engine.updateIDF(documents: entries.map(\.text))
        embeddings = [:]
        for entry in entries {
            embeddings[entry.id] = engine.embed(entry.text)
        }
        log.info("Rebuilt embeddings for \(self.entries.count) entries")
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
        guard retentionHours > 0 else { return }  // 0 = forever, skip purge
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
