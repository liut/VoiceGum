import Foundation

public enum LLMProvider: String, CaseIterable, Sendable {
    case ollama = "ollama"
    case openai = "openai"
    case azure = "azure"
    case anthropic = "anthropic"

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .openai: return "OpenAI"
        case .azure: return "Azure OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default: return true
        }
    }

    public var defaultModel: String {
        switch self {
        case .ollama: return "llama3.2"
        case .openai: return "gpt-4o-mini"
        case .azure: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-20250514"
        }
    }
}

public enum LLMClientError: LocalizedError {
    case notConfigured
    case requestFailed
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "LLM not configured"
        case .requestFailed: return "LLM request failed"
        case .invalidResponse: return "Invalid LLM response"
        }
    }
}

public actor LLMClient {
    public static let shared = LLMClient()

    private var baseURL: URL?
    private var apiKey: String?
    private var provider: LLMProvider = .openai
    private var model: String = "gpt-4o-mini"

    public init() {}

    public func configure(provider: LLMProvider, baseURL: URL, apiKey: String?, model: String) {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public func isConfigured() -> Bool {
        guard let _ = baseURL else { return false }
        if provider.requiresAPIKey {
            return apiKey != nil && !apiKey!.isEmpty
        }
        return true
    }

    public func refine(text: String) async throws -> String {
        guard let baseURL = baseURL else {
            throw LLMClientError.notConfigured
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if provider.requiresAPIKey, let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let systemPrompt = "You are a text refinement assistant. Improve the following transcribed speech for readability while preserving the meaning. Fix any transcription errors, add proper punctuation, and format appropriately."
        let userPrompt = "Please refine this text:\n\n\(text)"

        struct ChatRequest: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double = 0.7

            struct Message: Encodable {
                let role: String
                let content: String
            }
        }

        let payload = ChatRequest(
            model: model,
            messages: [
                ChatRequest.Message(role: "system", content: systemPrompt),
                ChatRequest.Message(role: "user", content: userPrompt)
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw LLMClientError.requestFailed
        }

        struct Response: Decodable {
            let choices: [Choice]
            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let content: String
                }
            }
        }

        let result = try JSONDecoder().decode(Response.self, from: data)
        return result.choices.first?.message.content ?? text
    }
}
