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
    case requestFailed(statusCode: Int, body: String)
    case decodeFailed(String)
    case networkFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "LLM 未配置"
        case .requestFailed(let code, let body):
            return "HTTP \(code): \(body.prefix(500))"
        case .decodeFailed(let detail):
            return "解析响应失败: \(detail)"
        case .networkFailed(let detail):
            return "网络错误: \(detail)"
        }
    }
}

public actor LLMClient {
    public static let shared = LLMClient()

    private var baseURL: URL?
    private var apiKey: String?
    private var provider: LLMProvider = .openai
    private var model: String = "gpt-4o-mini"

    /// Background URLSession to avoid blocking main queue with LLM API calls.
    /// URLSession.shared dispatches to main queue → "process not responding" during long requests.
    private nonisolated let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }()

    public init() {}

    public func configure(provider: LLMProvider, baseURL: URL, apiKey: String?, model: String) {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public func isConfigured() -> Bool {
        if provider == .ollama { return true }
        guard let _ = baseURL else { return false }
        if provider.requiresAPIKey {
            return apiKey != nil && !apiKey!.isEmpty
        }
        return true
    }

    /// Appends path to base URL, skipping duplicate leading segment if base URL's last path component matches.
    private nonisolated func buildURL(base: URL, path: String) -> URL {
        let baseLast = base.lastPathComponent
        let pathFirst = path.split(separator: "/").first.map(String.init) ?? ""
        if !baseLast.isEmpty && baseLast == pathFirst {
            let rest = path.split(separator: "/").dropFirst().joined(separator: "/")
            return base.appendingPathComponent(rest)
        }
        return base.appendingPathComponent(path)
    }

    /// Performs a data request on the background URLSession, resuming on the session's delegate queue.
    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            urlSession.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: LLMClientError.networkFailed("无数据或响应"))
                }
            }.resume()
        }
    }

    public func refine(text: String, customPrompt: String? = nil) async throws -> String {
        guard let baseURL = baseURL else {
            throw LLMClientError.notConfigured
        }

        let systemPrompt = (customPrompt?.isEmpty == false) ? customPrompt! : "You are a text refinement assistant."
        let userPrompt = "Please refine this text:\n\n\(text)"

        return try await send(systemPrompt: systemPrompt, userPrompt: userPrompt, baseURL: baseURL)
    }

    public func summarize(text: String, customPrompt: String? = nil) async throws -> String {
        guard let baseURL = baseURL else {
            throw LLMClientError.notConfigured
        }

        let systemPrompt = (customPrompt?.isEmpty == false) ? customPrompt! : "You are a text summarization assistant."
        let userPrompt = "Please summarize the following text:\n\n\(text)"

        return try await send(systemPrompt: systemPrompt, userPrompt: userPrompt, baseURL: baseURL)
    }

    private func send(systemPrompt: String, userPrompt: String, baseURL: URL) async throws -> String {
        switch provider {
        case .ollama:
            return try await ollamaChat(baseURL: baseURL, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        case .anthropic:
            return try await anthropicChat(baseURL: baseURL, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        default:
            return try await openaiChat(baseURL: baseURL, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
    }

    private func openaiChat(baseURL: URL, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let url = buildURL(base: baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        struct ChatRequest: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double = 0.7
            struct Message: Encodable { let role: String; let content: String }
        }

        let payload = ChatRequest(model: model, messages: [
            ChatRequest.Message(role: "system", content: systemPrompt),
            ChatRequest.Message(role: "user", content: userPrompt)
        ])
        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LLMClientError.networkFailed("编码请求失败: \(error.localizedDescription)") }
        await Logger.shared.info("OpenAI 请求: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")

        let data: Data, response: URLResponse
        do { (data, response) = try await performRequest( request) }
        catch { throw LLMClientError.networkFailed("\(error.localizedDescription) URL: \(url.absoluteString)") }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.networkFailed("无 HTTP 响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            await Logger.shared.info("OpenAI 错误响应: HTTP \(httpResponse.statusCode) body: \(body.prefix(500))")
            throw LLMClientError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
        await Logger.shared.info("OpenAI 响应: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "")")
        struct Resp: Decodable {
            let choices: [Choice]
            struct Choice: Decodable { let message: Msg; struct Msg: Decodable { let content: String } }
        }
        do {
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            let text = resp.choices.first?.message.content ?? userPrompt
            await Logger.shared.info("OpenAI 测试成功: \(text.prefix(200))")
            return text
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.decodeFailed("\(error.localizedDescription) body: \(body.prefix(500))")
        }
    }

    private func anthropicChat(baseURL: URL, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let url = buildURL(base: baseURL, path: "v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        struct AnthropicReq: Encodable {
            let model: String
            let max_tokens: Int = 4096
            let system: String
            let messages: [Message]
            struct Message: Encodable { let role: String; let content: String }
        }

        let payload = AnthropicReq(model: model, system: systemPrompt, messages: [
            AnthropicReq.Message(role: "user", content: userPrompt)
        ])
        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LLMClientError.networkFailed("编码请求失败: \(error.localizedDescription)") }
        await Logger.shared.info("Anthropic 请求: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")

        let data: Data, response: URLResponse
        do { (data, response) = try await performRequest( request) }
        catch { throw LLMClientError.networkFailed("\(error.localizedDescription) URL: \(url.absoluteString)") }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.networkFailed("无 HTTP 响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            await Logger.shared.info("Anthropic 错误响应: HTTP \(httpResponse.statusCode) body: \(body.prefix(500))")
            throw LLMClientError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
        await Logger.shared.info("Anthropic 响应: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "")")
        struct AnthropicResp: Decodable {
            let content: [Block]
            struct Block: Decodable {
                let type: String?
                let text: String?
            }
        }
        do {
            let resp = try JSONDecoder().decode(AnthropicResp.self, from: data)
            // Collect text from all blocks, skip thinking blocks
            let texts = resp.content.compactMap { $0.text }
            return texts.isEmpty ? userPrompt : texts.joined(separator: "\n")
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.decodeFailed("\(error.localizedDescription) body: \(body.prefix(300))")
        }
    }

    private func ollamaChat(baseURL: URL, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let url = buildURL(base: baseURL, path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct OllamaReq: Encodable {
            let model: String
            let messages: [Message]
            let stream: Bool = false
            struct Message: Encodable { let role: String; let content: String }
        }

        let payload = OllamaReq(model: model, messages: [
            OllamaReq.Message(role: "system", content: systemPrompt),
            OllamaReq.Message(role: "user", content: userPrompt)
        ])
        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LLMClientError.networkFailed("编码请求失败: \(error.localizedDescription)") }
        await Logger.shared.info("Ollama 请求: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")

        let data: Data, response: URLResponse
        do { (data, response) = try await performRequest( request) }
        catch { throw LLMClientError.networkFailed("\(error.localizedDescription) URL: \(url.absoluteString)") }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.networkFailed("无 HTTP 响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            await Logger.shared.info("Ollama 错误响应: HTTP \(httpResponse.statusCode) body: \(body.prefix(500))")
            throw LLMClientError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
        await Logger.shared.info("Ollama 响应: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "")")
        struct OllamaResp: Decodable {
            let message: Msg
            struct Msg: Decodable { let content: String }
        }
        do {
            let result = try JSONDecoder().decode(OllamaResp.self, from: data).message.content
            await Logger.shared.info("Ollama 测试成功: \(result.prefix(200))")
            return result
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.decodeFailed("\(error.localizedDescription) body: \(body.prefix(500))")
        }
    }
}
