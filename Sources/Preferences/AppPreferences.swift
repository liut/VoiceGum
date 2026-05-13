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
        static let llmEnabled = "voicegum.llmEnabled"
        static let llmProvider = "voicegum.llmProvider"
        static let llmBaseURL = "voicegum.llmBaseURL"
        static let llmModel = "voicegum.llmModel"
    }

    private init() {}

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

    public var llmEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmEnabled) }
    }

    public var llmProvider: String {
        get { defaults.string(forKey: Keys.llmProvider) ?? "openai" }
        set { defaults.set(newValue, forKey: Keys.llmProvider) }
    }

    public var llmBaseURL: String {
        get { defaults.string(forKey: Keys.llmBaseURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Keys.llmBaseURL) }
    }

    public var llmModel: String {
        get { defaults.string(forKey: Keys.llmModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Keys.llmModel) }
    }
}
