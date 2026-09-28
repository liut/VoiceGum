import XCTest
@testable import VoiceGumVoiceInput

final class VoiceInputEngineDecisionTests: XCTestCase {

    // MARK: - Preferred engine available

    func testSystemSpeechPreferredAndAvailable() {
        let decision = decideVoiceInputEngine(
            preference: .systemSpeech,
            systemSpeechAvailable: true,
            downloadedLocalFamilies: [.funASR, .senseVoice]
        )
        XCTAssertEqual(decision, .systemSpeech)
    }

    func testSenseVoicePreferredAndDownloaded() {
        let decision = decideVoiceInputEngine(
            preference: .senseVoice,
            systemSpeechAvailable: true,
            downloadedLocalFamilies: [.senseVoice]
        )
        XCTAssertEqual(decision, .local(.senseVoice))
    }

    func testFunASRNanoPreferredAndDownloaded() {
        let decision = decideVoiceInputEngine(
            preference: .funASR,
            systemSpeechAvailable: false,
            downloadedLocalFamilies: [.funASR]
        )
        XCTAssertEqual(decision, .local(.funASR))
    }

    // MARK: - System speech unavailable silently downgrades

    func testSystemSpeechUnavailableFallsBackToDownloadedLocalFamily() {
        let decision = decideVoiceInputEngine(
            preference: .systemSpeech,
            systemSpeechAvailable: false,
            downloadedLocalFamilies: [.senseVoice]
        )
        XCTAssertEqual(decision, .local(.senseVoice))
    }

    func testSystemSpeechUnavailableWithoutLocalModels() {
        let decision = decideVoiceInputEngine(
            preference: .systemSpeech,
            systemSpeechAvailable: false,
            downloadedLocalFamilies: []
        )
        XCTAssertEqual(decision, .modelNotDownloaded)
    }

    func testSystemSpeechUnavailablePrefersFunASRNanoWhenBothDownloaded() {
        let decision = decideVoiceInputEngine(
            preference: .systemSpeech,
            systemSpeechAvailable: false,
            downloadedLocalFamilies: [.senseVoice, .funASR]
        )
        XCTAssertEqual(decision, .local(.funASR))
    }

    // MARK: - Local preference is never substituted across families

    func testFunASRNanoPreferredButOnlySenseVoiceDownloaded() {
        let decision = decideVoiceInputEngine(
            preference: .funASR,
            systemSpeechAvailable: true,
            downloadedLocalFamilies: [.senseVoice]
        )
        XCTAssertEqual(decision, .modelNotDownloaded)
    }

    func testSenseVoicePreferredButOnlyFunASRNanoDownloaded() {
        let decision = decideVoiceInputEngine(
            preference: .senseVoice,
            systemSpeechAvailable: true,
            downloadedLocalFamilies: [.funASR]
        )
        XCTAssertEqual(decision, .modelNotDownloaded)
    }

    func testLocalPreferenceIgnoresSystemSpeechAvailability() {
        let decision = decideVoiceInputEngine(
            preference: .senseVoice,
            systemSpeechAvailable: false,
            downloadedLocalFamilies: [.senseVoice]
        )
        XCTAssertEqual(decision, .local(.senseVoice))
    }

    // MARK: - Stored preference fallback

    func testStoredPreferenceDefaultsToSystemSpeechWhenMissing() {
        XCTAssertEqual(VoiceInputEnginePreference(storedValue: nil), .systemSpeech)
    }

    func testStoredPreferenceFallsBackOnStaleValue() {
        XCTAssertEqual(VoiceInputEnginePreference(storedValue: "legacy-online"), .systemSpeech)
    }

    func testStoredPreferenceReadsKnownRawValue() {
        XCTAssertEqual(VoiceInputEnginePreference(storedValue: "funASR"), .funASR)
    }
}
