import Foundation

public final class AppPreferences: @unchecked Sendable {
    public static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "voicegum.language"
        static let asrProvider = "voicegum.asrProvider"
        static let asrModel = "voicegum.asrModel"
        static let asrAPIURL = "voicegum.asrAPIURL"
        static let onlineASRService = "voicegum.onlineASRService"
        static let volcAppId = "voicegum.volcAppId"
        static let volcResourceId = "voicegum.volcResourceId"
        static let volcAccessToken = "voicegum.volcAccessToken"
        static let llmProvider = "voicegum.llmProvider"
    }

    private init() {}

    // MARK: - ASR

    public var language: String {
        get { defaults.string(forKey: Keys.language) ?? "zh-CN" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    public var asrProvider: String {
        get { defaults.string(forKey: Keys.asrProvider) ?? "online" }
        set { defaults.set(newValue, forKey: Keys.asrProvider) }
    }

    public var asrModel: String {
        get { defaults.string(forKey: Keys.asrModel) ?? "whisper-1" }
        set { defaults.set(newValue, forKey: Keys.asrModel) }
    }

    public var asrAPIURL: String {
        get { defaults.string(forKey: Keys.asrAPIURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Keys.asrAPIURL) }
    }

    public var onlineASRService: String {
        get { defaults.string(forKey: Keys.onlineASRService) ?? "openai" }
        set { defaults.set(newValue, forKey: Keys.onlineASRService) }
    }

    public var volcAppId: String {
        get { defaults.string(forKey: Keys.volcAppId) ?? "" }
        set { defaults.set(newValue, forKey: Keys.volcAppId) }
    }

    public var volcResourceId: String {
        get { defaults.string(forKey: Keys.volcResourceId) ?? "volc.seedasr.sauc.duration" }
        set { defaults.set(newValue, forKey: Keys.volcResourceId) }
    }

    public var volcAccessToken: String {
        get { defaults.string(forKey: Keys.volcAccessToken) ?? "" }
        set { defaults.set(newValue, forKey: Keys.volcAccessToken) }
    }

    // MARK: - LLM (global)

    public var autoRefineEnabled: Bool {
        get { defaults.bool(forKey: "voicegum.llm.autoRefineEnabled") }
        set { defaults.set(newValue, forKey: "voicegum.llm.autoRefineEnabled") }
    }

    public var autoSummaryEnabled: Bool {
        get { defaults.bool(forKey: "voicegum.llm.autoSummaryEnabled") }
        set { defaults.set(newValue, forKey: "voicegum.llm.autoSummaryEnabled") }
    }

    public var llmProvider: String {
        get { defaults.string(forKey: Keys.llmProvider) ?? "openai" }
        set { defaults.set(newValue, forKey: Keys.llmProvider) }
    }

    // MARK: - LLM (per-provider)

    public func llmBaseURL(for provider: String? = nil) -> String {
        let p = provider ?? llmProvider
        let key = "voicegum.llm.\(p).baseURL"
        return defaults.string(forKey: key) ?? defaultBaseURL(for: p)
    }

    public func setLLMBaseURL(_ value: String, for provider: String? = nil) {
        let p = provider ?? llmProvider
        defaults.set(value, forKey: "voicegum.llm.\(p).baseURL")
    }

    public func llmModel(for provider: String? = nil) -> String {
        let p = provider ?? llmProvider
        let key = "voicegum.llm.\(p).model"
        return defaults.string(forKey: key) ?? defaultModel(for: p)
    }

    public func setLLMModel(_ value: String, for provider: String? = nil) {
        let p = provider ?? llmProvider
        defaults.set(value, forKey: "voicegum.llm.\(p).model")
    }

    // MARK: - LLM Task Prompts (provider-agnostic)

    public var refinePrompt: String {
        get { defaults.string(forKey: "voicegum.llm.refinePrompt") ?? defaultRefinePrompt }
        set { defaults.set(newValue, forKey: "voicegum.llm.refinePrompt") }
    }

    public var summaryPrompt: String {
        get { defaults.string(forKey: "voicegum.llm.summaryPrompt") ?? defaultSummaryPrompt }
        set { defaults.set(newValue, forKey: "voicegum.llm.summaryPrompt") }
    }

    private var defaultRefinePrompt: String {
        "You are a text refinement assistant. Improve the following transcribed speech for readability while preserving the meaning. Fix any transcription errors, add proper punctuation, and format appropriately."
    }

    private var defaultSummaryPrompt: String {
        "You are a text summarization assistant. Create a concise summary of the following transcribed text. Capture the key points and main ideas while keeping the summary brief and well-structured."
    }

    public func llmAPIKey(for provider: String? = nil) -> String {
        let p = provider ?? llmProvider
        return defaults.string(forKey: "voicegum.llm.\(p).apiKey") ?? ""
    }

    public func setLLMAPIKey(_ value: String, for provider: String? = nil) {
        let p = provider ?? llmProvider
        defaults.set(value, forKey: "voicegum.llm.\(p).apiKey")
    }

    private func defaultBaseURL(for provider: String) -> String {
        switch provider {
        case "anthropic": return "https://api.anthropic.com"
        case "ollama": return "http://localhost:11434"
        default: return "https://api.openai.com/v1"
        }
    }

    private func defaultModel(for provider: String) -> String {
        switch provider {
        case "anthropic": return "claude-haiku-3-5"
        case "ollama": return "llama3"
        default: return "gpt-4o-mini"
        }
    }
}
