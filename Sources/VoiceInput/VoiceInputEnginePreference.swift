import Foundation

/// 语音输入的优先引擎。持久化为原始字符串，读取时校验并回退默认值。
public enum VoiceInputEnginePreference: String, CaseIterable, Sendable {
    case systemSpeech
    case senseVoice
    case funASR

    public init(storedValue: String?) {
        self = storedValue.flatMap(VoiceInputEnginePreference.init(rawValue:)) ?? .systemSpeech
    }

    public var displayName: String {
        switch self {
        case .systemSpeech: "系统语音"
        case .senseVoice: "SenseVoice"
        case .funASR: "FunASR-Nano"
        }
    }
}

/// 本地模型家族。家族内部的具体量化版本沿用既有自动挑选。
enum VoiceInputLocalModelFamily: String, CaseIterable, Sendable {
    case senseVoice
    case funASR

    /// 系统语音不可用时本地模型的降级顺序，沿用升级前的 FunASR-Nano 优先。
    static let fallbackOrder: [VoiceInputLocalModelFamily] = [.funASR, .senseVoice]
}

/// 本次语音输入会话实际使用的引擎；`modelNotDownloaded` 表示首选为本地模型但该家族没有可用模型。
enum VoiceInputEngineDecision: Equatable, Sendable {
    case systemSpeech
    case local(VoiceInputLocalModelFamily)
    case modelNotDownloaded
}

/// 把偏好与可用性映射为本次会话的引擎决策。
func decideVoiceInputEngine(
    preference: VoiceInputEnginePreference,
    systemSpeechAvailable: Bool,
    downloadedLocalFamilies: Set<VoiceInputLocalModelFamily>
) -> VoiceInputEngineDecision {
    switch preference {
    case .systemSpeech:
        if systemSpeechAvailable { return .systemSpeech }
        guard let family = VoiceInputLocalModelFamily.fallbackOrder.first(where: downloadedLocalFamilies.contains) else {
            return .modelNotDownloaded
        }
        return .local(family)
    case .senseVoice:
        return downloadedLocalFamilies.contains(.senseVoice) ? .local(.senseVoice) : .modelNotDownloaded
    case .funASR:
        return downloadedLocalFamilies.contains(.funASR) ? .local(.funASR) : .modelNotDownloaded
    }
}
