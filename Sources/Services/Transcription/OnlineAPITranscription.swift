import Foundation

public actor OnlineAPITranscription: TranscriptionService {
    public let serviceName = "Online API"
    private let baseURL: URL
    private let apiKey: String?
    private let model: String

    public init(baseURL: URL, apiKey: String?, model: String = "whisper-1") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public func transcribe(file: URL, language: String) async throws -> TranscriptionResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"

        var headers: [String: String] = [
            "Accept": "application/json"
        ]
        if let apiKey = apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: file)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        let langCode = languageCode(for: language)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(langCode)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TranscriptionError.transcriptionFailed("HTTP \(statusCode)")
        }

        struct Response: Decodable {
            let text: String
        }

        let result = try JSONDecoder().decode(Response.self, from: data)
        return TranscriptionResult(text: result.text, timestamps: nil, language: language, confidence: nil)
    }

    private func languageCode(for language: String) -> String {
        switch language {
        case "zh-CN": return "zh"
        case "zh-TW": return "zh-TW"
        case "ja": return "ja"
        case "ko": return "ko"
        default: return "en"
        }
    }
}
