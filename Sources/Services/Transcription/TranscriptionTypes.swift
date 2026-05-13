import Foundation

public struct TranscriptionResult: Sendable, Codable {
    public let text: String
    public let timestamps: [Float]?
    public let language: String?
    public let confidence: Float?

    public init(text: String, timestamps: [Float]? = nil, language: String? = nil, confidence: Float? = nil) {
        self.text = text
        self.timestamps = timestamps
        self.language = language
        self.confidence = confidence
    }
}

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let sourceFileName: String
    public let timestamp: Date
    public let engineDescription: String
    public let language: String?
    public let duration: TimeInterval?
    public let text: String
    public let summaryText: String?

    public var displayTitle: String {
        if let s = summaryText, !s.isEmpty {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(30))
        }
        return sourceFileName
    }

    public init(id: String = UUID().uuidString, sourceFileName: String, timestamp: Date,
                engineDescription: String, language: String?, duration: TimeInterval?,
                text: String, summaryText: String?) {
        self.id = id
        self.sourceFileName = sourceFileName
        self.timestamp = timestamp
        self.engineDescription = engineDescription
        self.language = language
        self.duration = duration
        self.text = text
        self.summaryText = summaryText
    }
}

public enum TranscriptionError: LocalizedError {
    case invalidAudioFormat
    case transcriptionFailed(String)
    case networkError(Error)
    case modelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            return "Unsupported audio format"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .modelNotFound(let name):
            return "Model not found: \(name)"
        }
    }
}

public enum TranscriptionState: Sendable {
    case idle
    case validating(file: URL)
    case queued(files: [URL])
    case preparing(ASR: String)
    case transcribing(progress: Double, currentFile: Int, totalFiles: Int)
    case refining
    case completed(results: [TranscriptionResult], files: [URL])
    case failed(error: Error)
    case cancelled
}

public protocol TranscriptionService: Sendable {
    var serviceName: String { get }
    func transcribe(file: URL, language: String) async throws -> TranscriptionResult
}
