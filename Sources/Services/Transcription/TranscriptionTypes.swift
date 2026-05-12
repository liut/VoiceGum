import Foundation

public struct TranscriptionResult: Sendable {
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
