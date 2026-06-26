import Foundation

public enum TranslateOutputMode: String, CaseIterable, Sendable {
    case bilingual
    case translationOnly
}

public enum TranslateMode: String, CaseIterable, Sendable {
    case batch
    case perSegment
}

public final class AppPreferences: @unchecked Sendable {
    public static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "voicegum.language"
        static let asrProvider = "voicegum.asrProvider"
        static let asrEngine = "voicegum.asrEngine"
        static let asrModel = "voicegum.asrModel"
        static let asrAPIURL = "voicegum.asrAPIURL"
        static let onlineASRService = "voicegum.onlineASRService"
        static let volcAppId = "voicegum.volcAppId"
        static let volcResourceId = "voicegum.volcResourceId"
        static let volcAccessToken = "voicegum.volcAccessToken"
        static let subtitleExportEnabled = "voicegum.asr.subtitleExportEnabled"
        static let autoSaveHistory = "voicegum.asr.autoSaveHistory"
        static let llmProvider = "voicegum.llmProvider"
        static let autoTranslateEnabled = "voicegum.llm.autoTranslateEnabled"
        static let translateTargetLanguage = "voicegum.llm.translateTargetLanguage"
        static let translateOutputMode = "voicegum.llm.translateOutputMode"
        static let translateMode = "voicegum.llm.translateMode"
        static let translatePrompt = "voicegum.llm.translatePrompt"
        static let languageSplitEnabled = "voicegum.llm.languageSplitEnabled"
        static let llamaCLIThreads = "voicegum.llm.llamacli.threads"
    }

    private init() {
        sanitizeProvider()
    }

    private func sanitizeProvider() {
        let validProviders = ["ollama", "openai", "azure", "anthropic", "llamacli"]
        let current = defaults.string(forKey: Keys.llmProvider) ?? ""
        if !current.isEmpty, !validProviders.contains(current) {
            defaults.set("openai", forKey: Keys.llmProvider)
        }
    }

    // MARK: - ASR

    public var language: String {
        get { defaults.string(forKey: Keys.language) ?? "auto" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    public var asrProvider: String {
        get { defaults.string(forKey: Keys.asrProvider) ?? "online" }
        set { defaults.set(newValue, forKey: Keys.asrProvider) }
    }

    /// Local ASR engine: "legacy" (CAsrEngine) or "funasr" (CFunASREngine)
    public var asrEngine: String {
        get { defaults.string(forKey: Keys.asrEngine) ?? "legacy" }
        set { defaults.set(newValue, forKey: Keys.asrEngine) }
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

    public var subtitleExportEnabled: Bool {
        get { defaults.object(forKey: Keys.subtitleExportEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.subtitleExportEnabled) }
    }

    public var autoSaveHistory: Bool {
        get { defaults.object(forKey: Keys.autoSaveHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoSaveHistory) }
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

    // MARK: - Translation

    public var autoTranslateEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoTranslateEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoTranslateEnabled) }
    }

    public var translateTargetLanguage: String {
        get { defaults.string(forKey: Keys.translateTargetLanguage) ?? "zh-CN" }
        set { defaults.set(newValue, forKey: Keys.translateTargetLanguage) }
    }

    public var translateOutputMode: TranslateOutputMode {
        get {
            guard let raw = defaults.string(forKey: Keys.translateOutputMode),
                  let mode = TranslateOutputMode(rawValue: raw) else {
                return .bilingual
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.translateOutputMode) }
    }

    public var translateMode: TranslateMode {
        get {
            guard let raw = defaults.string(forKey: Keys.translateMode),
                  let mode = TranslateMode(rawValue: raw) else {
                return .batch
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.translateMode) }
    }

    public var translatePrompt: String {
        get { defaults.string(forKey: Keys.translatePrompt) ?? AppPreferences.defaultTranslatePrompt }
        set { defaults.set(newValue, forKey: Keys.translatePrompt) }
    }

    public var languageSplitEnabled: Bool {
        get { defaults.bool(forKey: Keys.languageSplitEnabled) }
        set { defaults.set(newValue, forKey: Keys.languageSplitEnabled) }
    }

    public var llamaCLIThreads: Int {
        get {
            let v = defaults.integer(forKey: Keys.llamaCLIThreads)
            return v > 0 ? v : 4
        }
        set { defaults.set(newValue, forKey: Keys.llamaCLIThreads) }
    }

    /// Whether `llama-cli` is available in PATH.
    public var isLLaMACLIAvailable: Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin"
        let dirs = path.split(separator: ":")
        for dir in dirs {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("llama-cli")
            if FileManager.default.isExecutableFile(atPath: p.path) { return true }
        }
        return false
    }

    public static let defaultTranslatePrompt = "你是一个专业的字幕翻译助手。请将以下文本翻译为目标语言，保持口语化的表达风格，不要添加任何解释或额外内容，只输出翻译结果。"

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
        return ""
    }
}
