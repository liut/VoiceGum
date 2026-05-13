import Foundation

public actor HistoryManager {
    public static let shared = HistoryManager()

    private let fileURL: URL
    private(set) public var entries: [HistoryEntry] = []

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Result")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    public func add(_ entry: HistoryEntry) {
        entries.append(entry)
        persist()
    }

    public func updateSummary(id: String, summaryText: String) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = HistoryEntry(
                id: entries[idx].id,
                sourceFileName: entries[idx].sourceFileName,
                timestamp: entries[idx].timestamp,
                engineDescription: entries[idx].engineDescription,
                language: entries[idx].language,
                duration: entries[idx].duration,
                text: entries[idx].text,
                summaryText: summaryText
            )
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
