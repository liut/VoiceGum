import XCTest
@testable import VoiceGumServices

@MainActor
final class SRTTranslationManagerTests: XCTestCase {

    // MARK: - Error types

    func testLLMNotConfiguredErrorDescription() {
        let err = SRTTranslationError.llmNotConfigured
        XCTAssertFalse(err.errorDescription?.isEmpty ?? true)
    }

    func testParseErrorWrapsSRTParseError() {
        let parseErr = SRTParser.SRTParseError.emptyFile
        let err = SRTTranslationError.parseError(parseErr)
        XCTAssertNotNil(err.errorDescription)
    }

    // MARK: - Translation manager lifecycle

    func testTranslationManagerExists() {
        let manager = SRTTranslationManager()
        XCTAssertNotNil(manager)
    }

    func testSRTTranslationErrorIsError() {
        let err: any Error = SRTTranslationError.llmNotConfigured
        XCTAssertNotNil(err)
    }
}
