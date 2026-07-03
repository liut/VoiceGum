import Foundation

public enum SRTParser {

    public enum SRTParseError: Error, LocalizedError {
        case emptyFile
        case invalidFormat(String)

        public var errorDescription: String? {
            switch self {
            case .emptyFile:
                return String(localized: "文件中未找到有效字幕")
            case .invalidFormat(let detail):
                return String(localized: "无法解析该文件，请确认其为有效的 SRT 字幕文件")
            }
        }
    }

    /// Parse SRT text content into an array of `SubtitleSegment`.
    public static func parse(_ content: String) throws -> [SubtitleSegment] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SRTParseError.emptyFile
        }

        let normalized = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Remove UTF-8 BOM if present
        let withoutBOM = normalized.hasPrefix("\u{FEFF}") ? String(normalized.dropFirst()) : normalized

        // Split into blocks by blank lines
        let rawBlocks = withoutBOM.components(separatedBy: "\n\n")
        let blocks = rawBlocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !blocks.isEmpty else {
            throw SRTParseError.emptyFile
        }

        var segments: [SubtitleSegment] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 2 else {
                throw SRTParseError.invalidFormat("Block has fewer than 2 lines")
            }

            // Line 0: index (skip — we don't need it)
            // Line 1: timecode
            let timecodeLine = lines[1]
            let timecodes = try parseTimecodeLine(timecodeLine)

            // Remaining lines: subtitle text
            let textLines = Array(lines.dropFirst(2))
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            segments.append(SubtitleSegment(
                text: text,
                startMs: timecodes.start,
                endMs: timecodes.end,
                language: nil
            ))
        }

        guard !segments.isEmpty else {
            throw SRTParseError.emptyFile
        }

        return segments
    }

    // MARK: - Private

    private static func parseTimecodeLine(_ line: String) throws -> (start: Float, end: Float) {
        // Handle variable whitespace around arrow: "00:00:01,000 --> 00:00:05,000"
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else {
            throw SRTParseError.invalidFormat("Invalid timecode line: \(line)")
        }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        let startMs = try parseTimestamp(startStr)
        let endMs = try parseTimestamp(endStr)

        return (startMs, endMs)
    }

    private static func parseTimestamp(_ str: String) throws -> Float {
        // Format: HH:MM:SS,mmm or HH:MM:SS.mmm
        let cleaned = str.replacingOccurrences(of: ",", with: ".")
        let components = cleaned.components(separatedBy: ":")
        guard components.count == 3 else {
            throw SRTParseError.invalidFormat("Invalid timestamp: \(str)")
        }

        guard let hours = Float(components[0]),
              let minutes = Float(components[1]),
              let seconds = Float(components[2]) else {
            throw SRTParseError.invalidFormat("Invalid timestamp values: \(str)")
        }

        return hours * 3600000 + minutes * 60000 + seconds * 1000
    }
}
