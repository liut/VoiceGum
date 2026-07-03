import XCTest
@testable import VoiceGumServices

final class SRTParserTests: XCTestCase {

    // MARK: - Happy path

    func testSingleSegment() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:05,000
        Hello world
        """

        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello world")
        XCTAssertEqual(segments[0].startMs, 1000)
        XCTAssertEqual(segments[0].endMs, 5000)
        XCTAssertNil(segments[0].language)
    }

    func testMultiSegment() throws {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,500
        First line

        2
        00:00:03,000 --> 00:00:06,000
        Second line
        """

        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First line")
        XCTAssertEqual(segments[1].text, "Second line")
    }

    func testMultiLineText() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:05,000
        Line one
        Line two
        """

        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Line one\nLine two")
    }

    func testTrailingBlankLines() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:05,000
        Hello


        """
        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 1)
    }

    // MARK: - Edge cases

    func testCRLFLineEndings() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:05,000\r\nHello\r\n"
        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello")
    }

    func testUTF8BOM() throws {
        let srt = "\u{FEFF}1\n00:00:01,000 --> 00:00:05,000\nHello\n"
        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello")
    }

    func testVariableWhitespaceAroundArrow() throws {
        let srt = """
        1
        00:00:01,000  -->  00:00:05,000
        Hello
        """
        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 1)
    }

    func testEmptyTextSegment() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:05,000


        2
        00:00:06,000 --> 00:00:10,000
        Has text
        """
        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "")
        XCTAssertEqual(segments[1].text, "Has text")
    }

    func testDotSeparatedTimecode() throws {
        let srt = """
        1
        00:00:01.000 --> 00:00:05.500
        Hello
        """
        let segments = try SRTParser.parse(srt)
        XCTAssertEqual(segments[0].startMs, 1000)
        XCTAssertEqual(segments[0].endMs, 5500)
    }

    // MARK: - Error paths

    func testEmptyStringThrows() {
        XCTAssertThrowsError(try SRTParser.parse("")) { error in
            XCTAssertTrue(error is SRTParser.SRTParseError)
        }
    }

    func testWhitespaceOnlyStringThrows() {
        XCTAssertThrowsError(try SRTParser.parse("   \n\n  ")) { error in
            XCTAssertTrue(error is SRTParser.SRTParseError)
        }
    }

    func testNonSRTContentThrows() {
        let garbage = "This is not an SRT file at all"
        XCTAssertThrowsError(try SRTParser.parse(garbage)) { error in
            XCTAssertTrue(error is SRTParser.SRTParseError)
        }
    }

    func testMalformedTimecodeThrows() {
        let srt = """
        1
        abc:def:ghi --> jkl:mno:pqr
        Non-numeric timecode
        """
        XCTAssertThrowsError(try SRTParser.parse(srt)) { error in
            XCTAssertTrue(error is SRTParser.SRTParseError)
        }
    }

    func testMissingArrowThrows() {
        let srt = """
        1
        00:00:01,000
        No arrow line
        """
        XCTAssertThrowsError(try SRTParser.parse(srt)) { error in
            XCTAssertTrue(error is SRTParser.SRTParseError)
        }
    }

    // MARK: - Integration: round-trip

    func testRoundTrip() throws {
        let original: [SubtitleSegment] = [
            SubtitleSegment(text: "Hello", startMs: 1000, endMs: 5000),
            SubtitleSegment(text: "World", startMs: 6000, endMs: 10000),
        ]
        let srt = SubtitleFormatter.toSRT(original)
        XCTAssertFalse(srt.isEmpty)

        let parsed = try SRTParser.parse(srt)
        XCTAssertEqual(parsed.count, 2)
        // After smartSplit, text and timings may be adjusted, so we check count only
    }
}
