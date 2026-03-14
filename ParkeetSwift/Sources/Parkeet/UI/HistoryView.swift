import SwiftUI

/// Transcription history with search, expandable rows, and copy/clear actions.
struct HistoryView: View {
    @Bindable var historyStore: HistoryStore
    @Bindable var config: Config
    @State private var searchText = ""
    @State private var expandedID: UUID?

    private var filteredEntries: [HistoryEntry] {
        if searchText.isEmpty {
            return historyStore.entries
        }
        let query = searchText.lowercased()

        // Keyword matches first
        let keywordMatches = historyStore.entries.filter {
            $0.text.lowercased().contains(query) ||
            ($0.sourceFilename?.lowercased().contains(query) ?? false)
        }

        // Semantic matches (exclude keyword matches)
        let keywordIDs = Set(keywordMatches.map(\.id))
        let semanticMatches: [(entry: HistoryEntry, score: Double)]

        if let engine = historyStore.embeddingEngine,
           let queryVec = engine.embed(searchText) {
            semanticMatches = historyStore.entries
                .filter { !keywordIDs.contains($0.id) }
                .compactMap { entry -> (entry: HistoryEntry, score: Double)? in
                    guard let entryVec = historyStore.embeddings[entry.id] else { return nil }
                    let score = engine.cosineSimilarity(queryVec, entryVec)
                    return score > 0.3 ? (entry, score) : nil
                }
                .sorted { $0.score > $1.score }
        } else {
            semanticMatches = []
        }

        return keywordMatches + semanticMatches.map(\.entry)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search transcriptions…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)
            .padding()

            // Retention setting
            HStack {
                Text("Keep history for")
                Picker("", selection: Binding(
                    get: { config.historyRetentionHours },
                    set: {
                        config.historyRetentionHours = $0
                        historyStore.updateRetention(hours: $0)
                    }
                )) {
                    Text("24 hours").tag(24.0)
                    Text("48 hours").tag(48.0)
                    Text("7 days").tag(168.0)
                    Text("30 days").tag(720.0)
                    Text("Forever").tag(0.0)
                }
                .frame(width: 120)

                Spacer()

                Button("Clear All") {
                    historyStore.clear()
                }
                .disabled(historyStore.entries.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Entry list
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Transcriptions" : "No Results",
                    systemImage: searchText.isEmpty ? "clock" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "Your transcription history will appear here."
                        : "No transcriptions match '\(searchText)'.")
                )
            } else {
                List(filteredEntries) { entry in
                    let isSemantic = !searchText.isEmpty &&
                        !(entry.text.lowercased().contains(searchText.lowercased()) ||
                          (entry.sourceFilename?.lowercased().contains(searchText.lowercased()) ?? false))

                    HistoryRowView(
                        entry: entry,
                        isExpanded: expandedID == entry.id,
                        isSemantic: isSemantic,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedID = expandedID == entry.id ? nil : entry.id
                            }
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - History Row

struct HistoryRowView: View {
    let entry: HistoryEntry
    let isExpanded: Bool
    var isSemantic: Bool = false
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header (always visible)
            HStack {
                // Type badge
                Circle()
                    .fill(entry.type == .hotkey ? .blue : .green)
                    .frame(width: 8, height: 8)

                if isSemantic {
                    Text("Similar")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .cornerRadius(3)
                }

                // Preview text (hidden when expanded to avoid duplication)
                if !isExpanded {
                    Text(previewText)
                        .lineLimit(1)
                        .font(.system(size: 13))
                }

                Spacer()

                // Timestamp
                Text(relativeTimestamp)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Expand chevron
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)

                    HStack {
                        Text("\(entry.wordCount) words")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let filename = entry.sourceFilename {
                            Text("from \(filename)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.text, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    private var previewText: String {
        let text = entry.text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 80 {
            return String(text.prefix(80)) + "…"
        }
        return text
    }

    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.timestamp, relativeTo: Date())
    }
}
