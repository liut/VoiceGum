import Foundation
import NaturalLanguage

public enum SubtitleFormatter {

    /// Convert subtitle segments to SRT format string.
    public static func toSRT(_ segments: [SubtitleSegment]?) -> String {
        guard let segments = segments, !segments.isEmpty else { return "" }

        let merged = mergeShortSegments(segments)
        let split = smartSplit(merged)
        return formatSRT(split)
    }

    /// Format milliseconds to SRT timecode: HH:MM:SS,mmm
    public static func formatTime(_ ms: Float) -> String {
        let totalMs = Int(max(0, ms))
        let h = totalMs / 3600000
        let m = (totalMs % 3600000) / 60000
        let s = (totalMs % 60000) / 1000
        let msPart = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, msPart)
    }

    // MARK: - Constants

    private static let targetChars = 42
    private static let maxSeconds: Float = 5
    private static let minTrailingChars = 15

    // MARK: - Text range

    private struct TextRange {
        let text: String
        let start: Int  // byte offset in original segment text
        let end: Int
        var charCount: Int { text.count }
    }

    // MARK: - Stage 1 — merge short segments (< 300ms)

    private static func mergeShortSegments(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        guard segments.count > 1 else { return segments }
        var result: [SubtitleSegment] = [segments[0]]
        for i in 1..<segments.count {
            let seg = segments[i]
            if seg.endMs - seg.startMs < 300 {
                let prev = result.removeLast()
                result.append(SubtitleSegment(
                    text: prev.text + " " + seg.text,
                    startMs: prev.startMs,
                    endMs: seg.endMs
                ))
            } else {
                result.append(seg)
            }
        }
        return result
    }

    // MARK: - Stage 2 — smart split at natural boundaries

    private static func smartSplit(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        var result: [SubtitleSegment] = []
        for seg in segments {
            let duration = seg.endMs - seg.startMs
            let chars = seg.text.count
            let nByChars = max(1, (chars + targetChars - 1) / targetChars)
            let nByTime = max(1, Int((duration / 1000 / maxSeconds).rounded(.up)))
            if max(nByChars, nByTime) <= 1 {
                result.append(seg)
            } else {
                result.append(contentsOf: naturalSplit(seg))
            }
        }
        return result
    }

    /// Split at sentence boundaries first, then word boundaries for over-long sentences.
    private static func naturalSplit(_ seg: SubtitleSegment) -> [SubtitleSegment] {
        let sentences = findSentences(seg.text)
        let grouped = groupSentences(sentences, seg: seg)
        return grouped.flatMap { range in
            let s = estSec(range.charCount, seg)
            if range.charCount > targetChars || s > maxSeconds {
                return splitAtWords(range, seg: seg)
            }
            return [makeSegment(range, seg: seg)]
        }
    }

    /// Accumulate sentences into chunks respecting char + time limits.
    private static func groupSentences(_ sentences: [TextRange], seg: SubtitleSegment) -> [TextRange] {
        let duration = seg.endMs - seg.startMs
        let totalChars = seg.text.count

        var result: [TextRange] = []
        var buf = ""
        var bufStart = 0
        var bufEnd = 0

        for s in sentences {
            let combined = buf + s.text
            let estSec = totalChars > 0
                ? duration * Float(s.end - bufStart) / Float(totalChars) / 1000
                : 0

            if !buf.isEmpty && (combined.count > targetChars || estSec > maxSeconds) {
                result.append(TextRange(text: buf, start: bufStart, end: bufEnd))
                buf = s.text
                bufStart = s.start
            } else {
                if buf.isEmpty { bufStart = s.start }
                buf += s.text
            }
            bufEnd = s.end
        }
        if !buf.isEmpty {
            result.append(TextRange(text: buf, start: bufStart, end: bufEnd))
        }
        return result
    }

    /// Split an over-long text block at word boundaries, aiming for balanced chunks.
    /// Extracts text from the original string by offset to preserve inter-word spacing.
    private static func splitAtWords(_ range: TextRange, seg: SubtitleSegment) -> [SubtitleSegment] {
        let words = findWords(range.text)
        if words.isEmpty { return splitBySpaces(range, seg: seg) }

        let duration = seg.endMs - seg.startMs
        let totalChars = seg.text.count
        let localDuration = duration * Float(range.charCount) / Float(max(totalChars, 1))

        let nByChars = max(1, (range.charCount + targetChars - 1) / targetChars)
        let nByTime = max(1, Int((localDuration / 1000 / maxSeconds).rounded(.up)))
        let n = max(nByChars, nByTime)

        guard n > 1 else { return [makeSegment(range, seg: seg)] }

        // Find word boundaries near evenly-spaced positions
        let targetPer = range.charCount / n
        var splitAt: [Int] = []  // word indices to split AFTER
        var prevSplit = -1

        for k in 1..<n {
            let targetChar = k * targetPer
            var best = -1
            for (j, w) in words.enumerated() where j > prevSplit {
                if w.end <= targetChar { best = j } else { break }
            }
            // Don't split if trailing portion would be too short
            if best > prevSplit {
                let trailing = (words.last?.end ?? 0) - words[best + 1 < words.count ? best + 1 : best].start
                if best + 1 < words.count, trailing < minTrailingChars {
                    // Search backward for a more balanced split
                    for j in stride(from: best, through: max(prevSplit + 1, 0), by: -1) {
                        let t = (words.last?.end ?? 0) - words[j + 1 < words.count ? j + 1 : j].start
                        if t >= minTrailingChars { best = j; break }
                    }
                }
                if best > prevSplit {
                    splitAt.append(best)
                    prevSplit = best
                }
            }
        }

        // If no good word-level splits, fall back to space-based, then force
        guard !splitAt.isEmpty else {
            let spaceResult = splitBySpaces(range, seg: seg)
            if spaceResult.count > 1 { return spaceResult }
            return forceChunk(SubtitleSegment(
                text: range.text,
                startMs: seg.startMs + duration * Float(range.start) / Float(max(totalChars, 1)),
                endMs: seg.startMs + duration * Float(range.end) / Float(max(totalChars, 1))
            ))
        }

        // Build chunks at split positions
        var result: [SubtitleSegment] = []
        var chunkStart = 0
        for splitIdx in splitAt {
            let gStart = range.start + words[chunkStart].start
            let gEnd = range.start + words[splitIdx].end
            let text = extractText(seg.text, from: gStart, to: gEnd)
            result.append(makeSegment(
                TextRange(text: text, start: gStart, end: gEnd), seg: seg))
            chunkStart = splitIdx + 1
        }
        if chunkStart < words.count {
            let gStart = range.start + words[chunkStart].start
            let gEnd = range.start + (words.last?.end ?? 0)
            let text = extractText(seg.text, from: gStart, to: gEnd)
            result.append(makeSegment(
                TextRange(text: text, start: gStart, end: gEnd), seg: seg))
        }

        // Final enforcement: any chunk still over limits gets mechanically split
        var final: [SubtitleSegment] = []
        for chunk in result {
            let dur = (chunk.endMs - chunk.startMs) / 1000
            if chunk.text.count > targetChars || dur > maxSeconds {
                final.append(contentsOf: forceChunk(chunk))
            } else {
                final.append(chunk)
            }
        }
        return final
    }

    private static func estSec(_ charCount: Int, _ seg: SubtitleSegment) -> Float {
        let chars = seg.text.count
        guard chars > 0 else { return 0 }
        return (seg.endMs - seg.startMs) * Float(charCount) / Float(chars) / 1000
    }

    private static func extractText(_ text: String, from start: Int, to end: Int) -> String {
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: min(end, text.count))
        return String(text[lower..<upper])
    }

    /// Last resort: split by character count (no boundary awareness).
    private static func forceChunk(_ seg: SubtitleSegment) -> [SubtitleSegment] {
        let text = seg.text
        let duration = seg.endMs - seg.startMs
        let chars = text.count
        let nByChars = max(1, (chars + targetChars - 1) / targetChars)
        let nByTime = max(1, Int((duration / 1000 / maxSeconds).rounded(.up)))
        let n = max(nByChars, nByTime)
        let per = (chars + n - 1) / n

        var chunks: [SubtitleSegment] = []
        var offset = 0
        for _ in 0..<n {
            let start = offset
            let end = min(offset + per, chars)
            let sub = String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
            chunks.append(SubtitleSegment(
                text: sub,
                startMs: seg.startMs + duration * Float(start) / Float(chars),
                endMs: seg.startMs + duration * Float(end) / Float(chars)
            ))
            offset = end
            if offset >= chars { break }
        }
        return chunks
    }

    // MARK: - Space-based fallback (when NLTokenizer returns no words)

    private static func splitBySpaces(_ range: TextRange, seg: SubtitleSegment) -> [SubtitleSegment] {
        let parts = range.text.components(separatedBy: " ")
        guard parts.count > 1 else {
            return forceChunk(SubtitleSegment(
                text: range.text,
                startMs: seg.startMs + (seg.endMs - seg.startMs) * Float(range.start) / Float(seg.text.count),
                endMs: seg.startMs + (seg.endMs - seg.startMs) * Float(range.end) / Float(seg.text.count)
            ))
        }

        // Rebuild word list preserving spaces
        var wordRanges: [TextRange] = []
        var pos = 0
        for (i, part) in parts.enumerated() {
            let token = i < parts.count - 1 ? part + " " : part
            wordRanges.append(TextRange(text: token, start: pos, end: pos + token.count))
            pos += token.count
        }

        var result: [SubtitleSegment] = []
        var buf = ""
        var bufStart = range.start

        for wr in wordRanges {
            let combined = buf + wr.text
            if !buf.isEmpty && combined.count > targetChars {
                result.append(makeSegment(
                    TextRange(text: buf, start: bufStart, end: range.start + wr.start),
                    seg: seg
                ))
                buf = wr.text
                bufStart = range.start + wr.start
            } else {
                if buf.isEmpty { bufStart = range.start + wr.start }
                buf += wr.text
            }
        }
        if !buf.isEmpty {
            result.append(makeSegment(
                TextRange(text: buf, start: bufStart, end: range.end),
                seg: seg
            ))
        }
        return result
    }

    // MARK: - NLTokenizer wrappers

    private static func findSentences(_ text: String) -> [TextRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [TextRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            ranges.append(TextRange(text: String(text[range]), start: start, end: end))
            return true
        }
        return ranges.isEmpty ? [TextRange(text: text, start: 0, end: text.count)] : ranges
    }

    private static func findWords(_ text: String) -> [TextRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [TextRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            ranges.append(TextRange(text: String(text[range]), start: start, end: end))
            return true
        }
        return ranges
    }

    // MARK: - Helpers

    private static func makeSegment(_ range: TextRange, seg: SubtitleSegment) -> SubtitleSegment {
        let duration = seg.endMs - seg.startMs
        let chars = seg.text.count
        return SubtitleSegment(
            text: range.text,
            startMs: seg.startMs + duration * Float(range.start) / Float(chars),
            endMs: seg.startMs + duration * Float(range.end) / Float(chars)
        )
    }

    // MARK: - Stage 3 — SRT output

    private static func formatSRT(_ segments: [SubtitleSegment]) -> String {
        var result = ""
        for (index, seg) in segments.enumerated() {
            result += "\(index + 1)\n"
            result += "\(formatTime(seg.startMs)) --> \(formatTime(seg.endMs))\n"
            result += "\(seg.text)\n\n"
        }
        return result
    }
}
