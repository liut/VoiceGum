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

    public func updateRefinedText(id: String, refinedText: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries[idx]
        entries[idx] = HistoryEntry(
            id: e.id, sourceFileName: e.sourceFileName, timestamp: e.timestamp,
            engineDescription: e.engineDescription, language: e.language, duration: e.duration,
            rawText: e.rawText, refinedText: refinedText, summaryText: e.summaryText,
            segments: e.segments
        )
        persist()
    }

    public func updateTranslatedText(id: String, translatedText: String?, translatedSegments: [SubtitleSegment]?, translateTargetLanguage: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries[idx]
        entries[idx] = HistoryEntry(
            id: e.id, sourceFileName: e.sourceFileName, timestamp: e.timestamp,
            engineDescription: e.engineDescription, language: e.language, duration: e.duration,
            rawText: e.rawText, refinedText: e.refinedText, summaryText: e.summaryText,
            segments: e.segments,
            translatedText: translatedText, translatedSegments: translatedSegments,
            translateTargetLanguage: translateTargetLanguage
        )
        persist()
    }

    public func updateSummary(id: String, summaryText: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries[idx]
        entries[idx] = HistoryEntry(
            id: e.id, sourceFileName: e.sourceFileName, timestamp: e.timestamp,
            engineDescription: e.engineDescription, language: e.language, duration: e.duration,
            rawText: e.rawText, refinedText: e.refinedText, summaryText: summaryText,
            segments: e.segments
        )
        persist()
    }

    public func delete(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
