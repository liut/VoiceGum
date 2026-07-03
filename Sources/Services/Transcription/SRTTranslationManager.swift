import Foundation
import VoiceGumPreferences

public enum SRTTranslationError: Error, LocalizedError {
    case llmNotConfigured
    case parseError(SRTParser.SRTParseError)
    case writeFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .llmNotConfigured:
            return String(localized: "请先在设置中配置 LLM")
        case .parseError(let parseErr):
            return parseErr.errorDescription
        case .writeFailed(let error):
            return String(localized: "写入文件失败: \(error.localizedDescription)")
        }
    }
}

@MainActor
public final class SRTTranslationManager {

    private nonisolated let maxSegmentsPerChunk = 80

    public init() {}

    /// Translate an SRT file and write the result alongside the source.
    /// - Parameters:
    ///   - url: Path to the source SRT file
    ///   - progress: Callback with (completed, total) segment counts
    /// - Returns: URL of the output file
    public func translate(file url: URL, progress: @Sendable (Int, Int) -> Void) async throws -> URL {
        // 1. Read file
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SRTTranslationError.parseError(.invalidFormat("Failed to read file: \(error.localizedDescription)"))
        }

        // 2. Parse
        let segments: [SubtitleSegment]
        do {
            segments = try SRTParser.parse(content)
        } catch let parseErr as SRTParser.SRTParseError {
            throw SRTTranslationError.parseError(parseErr)
        }

        // 3. Configure LLM client
        try await configureLLMClient()
        guard await LLMClient.shared.isConfigured() else {
            throw SRTTranslationError.llmNotConfigured
        }

        // 4. Read preferences
        let translateMode = AppPreferences.shared.translateMode
        let outputMode = AppPreferences.shared.translateOutputMode
        let targetLang = AppPreferences.shared.translateTargetLanguage
        let prompt = AppPreferences.shared.translatePrompt
        let customPrompt = prompt.isEmpty ? nil : prompt

        await Logger.shared.info("SRT 翻译开始: \(url.lastPathComponent) → \(targetLang), \(segments.count) 段, 模式: \(translateMode == .batch ? "整批" : "逐条")")

        // 5. Translate
        let translatedSegments: [SubtitleSegment]
        if translateMode == .batch {
            translatedSegments = try await translateBatch(
                segments: segments, targetLang: targetLang, customPrompt: customPrompt, progress: progress)
        } else {
            translatedSegments = try await translatePerSegment(
                segments: segments, targetLang: targetLang, customPrompt: customPrompt, progress: progress)
        }

        // 6. Format output
        let srtText: String
        switch outputMode {
        case .bilingual:
            srtText = SubtitleFormatter.toSRTBilingual(original: segments, translated: translatedSegments)
        case .translationOnly:
            srtText = SubtitleFormatter.toSRT(translatedSegments)
        }
        guard !srtText.isEmpty else {
            throw SRTTranslationError.parseError(.emptyFile)
        }

        // 7. Write output
        let outputURL = makeOutputURL(source: url, targetLang: targetLang)
        do {
            try srtText.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            await Logger.shared.error("SRT 翻译写入失败: \(error.localizedDescription)")
            throw SRTTranslationError.writeFailed(error)
        }

        await Logger.shared.info("SRT 翻译完成: \(outputURL.path)")
        return outputURL
    }

    // MARK: - Translation modes

    private func translatePerSegment(segments: [SubtitleSegment], targetLang: String,
                                      customPrompt: String?,
                                      progress: @Sendable (Int, Int) -> Void) async throws -> [SubtitleSegment] {
        var translated: [SubtitleSegment] = []
        let total = segments.count

        for (i, seg) in segments.enumerated() {
            try Task.checkCancellation()
            let text = try await LLMClient.shared.translate(
                text: seg.text, targetLanguage: targetLang, customPrompt: customPrompt)
            translated.append(SubtitleSegment(
                text: text, startMs: seg.startMs, endMs: seg.endMs, language: seg.language))
            progress(i + 1, total)
        }

        return translated
    }

    private func translateBatch(segments: [SubtitleSegment], targetLang: String,
                                 customPrompt: String?,
                                 progress: @Sendable (Int, Int) -> Void) async throws -> [SubtitleSegment] {
        let chunks = chunkSegments(segments)
        var allTranslated: [SubtitleSegment] = []
        var completedCount = 0

        for chunk in chunks {
            try Task.checkCancellation()

            var markedText = ""
            let segs = chunk.map { $0.1 }
            for (i, seg) in chunk {
                markedText += "[SEGMENT \(i + 1)]\n\(seg.text)\n[/SEGMENT \(i + 1)]\n"
            }
            let instruction = "Keep the [SEGMENT N] and [/SEGMENT N] markers exactly as-is. Translate only the text between each marker pair — do not merge or reorder segments. Each output segment must correspond 1:1 to the input segment.\n\n"

            let raw = try await LLMClient.shared.translate(
                text: instruction + markedText, targetLanguage: targetLang, customPrompt: customPrompt)
            let parsed = parseTranslatedSegments(raw: raw, original: segs)
            allTranslated.append(contentsOf: parsed)
            completedCount += chunk.count
            progress(min(completedCount, segments.count), segments.count)
        }

        return allTranslated
    }

    // MARK: - Helpers

    private func configureLLMClient() async throws {
        let providerStr = AppPreferences.shared.llmProvider
        let provider: LLMProvider = switch providerStr {
        case "anthropic": .anthropic
        case "ollama": .ollama
        case "llamacli": .llamaCLI
        default: .openai
        }
        let baseURL = provider == .llamaCLI
            ? URL(string: "http://localhost")!
            : URL(string: AppPreferences.shared.llmBaseURL())
        guard let baseURL else { throw SRTTranslationError.llmNotConfigured }
        let apiKey = AppPreferences.shared.llmAPIKey()
        await LLMClient.shared.configure(provider: provider, baseURL: baseURL,
                                          apiKey: apiKey.isEmpty ? nil : apiKey,
                                          model: AppPreferences.shared.llmModel())
    }

    private nonisolated func chunkSegments(_ segments: [SubtitleSegment]) -> [[(Int, SubtitleSegment)]] {
        var chunks: [[(Int, SubtitleSegment)]] = []
        var current: [(Int, SubtitleSegment)] = []
        for (i, seg) in segments.enumerated() {
            current.append((i, seg))
            if current.count >= maxSegmentsPerChunk {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private nonisolated func parseTranslatedSegments(raw: String, original: [SubtitleSegment]) -> [SubtitleSegment] {
        var result: [SubtitleSegment] = []
        for (i, seg) in original.enumerated() {
            let openMarker = "[SEGMENT \(i + 1)]"
            let closeMarker = "[/SEGMENT \(i + 1)]"
            guard let openRange = raw.range(of: openMarker),
                  let closeRange = raw.range(of: closeMarker),
                  openRange.upperBound < closeRange.lowerBound else { continue }
            var startIdx = openRange.upperBound
            while startIdx < closeRange.lowerBound, raw[startIdx].isNewline || raw[startIdx].isWhitespace {
                startIdx = raw.index(after: startIdx)
            }
            var endIdx = closeRange.lowerBound
            while endIdx > startIdx {
                let prev = raw.index(before: endIdx)
                if raw[prev].isNewline || raw[prev].isWhitespace { endIdx = prev } else { break }
            }
            guard startIdx < endIdx else { continue }
            let translatedText = String(raw[startIdx..<endIdx])
            result.append(SubtitleSegment(text: translatedText, startMs: seg.startMs,
                                          endMs: seg.endMs, language: seg.language))
        }
        return result
    }

    private nonisolated func languageSuffix(_ language: String?) -> String {
        guard let lang = language?.lowercased(), !lang.isEmpty else { return "und" }
        if lang == "auto" { return "auto" }
        if lang.hasPrefix("zh-cn") || lang == "zh" { return "chs" }
        if lang.hasPrefix("zh-tw") || lang.hasPrefix("zh-hk") { return "cht" }
        if lang.hasPrefix("en") { return "en" }
        if lang.hasPrefix("ja") { return "ja" }
        if lang.hasPrefix("ko") { return "ko" }
        return lang.replacingOccurrences(of: "-", with: "_")
    }

    private func makeOutputURL(source: URL, targetLang: String) -> URL {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let langCode = languageSuffix(targetLang)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var ts = formatter.string(from: Date())
        ts = ts.replacingOccurrences(of: ":", with: "")

        let filename = "\(stem)_\(ts).\(langCode).srt"
        return dir.appendingPathComponent(filename)
    }
}
