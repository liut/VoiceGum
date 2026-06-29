import Foundation
import AVFoundation
import AppKit
import VoiceGumServices
import VoiceGumPreferences
import VoiceGumKeychain

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var droppedFileURL: URL?
    @Published var statusMessage: String = ""
    @Published var summaryText: String?
    @Published var isSummarizing = false
    @Published var isRefining = false

    var refineDisabled: Bool { hasRefined || isRefining }

    private var transcriptionService: TranscriptionService?
    private var currentTask: Task<Void, Never>?
    private var summarizeTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var hasRefined = false
    private var lastHistoryEntryIds: [String] = []
    private var transcriptionDuration: TimeInterval?
    private var targetProgress: Double = 0
    private var displayTimer: Timer?
    private var transcriptionStartTime: Date?

    init() {
        setupLocalService()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenFile),
            name: .voiceGumOpenFile, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillTerminate),
            name: .voiceGumWillTerminate, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWillTerminate(_ notification: Notification) {
        stopProgressTimer()
        currentTask?.cancel()
        summarizeTask?.cancel()
        refineTask?.cancel()
    }

    @objc private func handleOpenFile(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        reset()
        droppedFileURL = url
    }

    private func setupLocalService() {
        guard AppPreferences.shared.asrProvider != "online" else { return }
        let savedId = AppPreferences.shared.asrModel
        // Validate the saved model is still in the catalog — prevents crash
        // when a removed model (e.g. Qwen3-ASR) lingers in UserDefaults
        guard let model = model(for: savedId) else {
            AppPreferences.shared.asrModel = "sense-voice-fp16"
            return
        }
        guard isModelDownloaded(model.id) else { return }
        if model.id.hasPrefix("funasr-nano") {
            let svc = FunASRNanoTranscriptionService(modelId: model.id)
            try? svc.loadModel()
            transcriptionService = svc
        } else if AppPreferences.shared.asrEngine == "funasr" {
            let svc = FunASRTranscriptionService(modelId: model.id)
            try? svc.loadModel()
            transcriptionService = svc
        } else {
            let svc = GGMLTranscriptionService(modelId: model.id)
            try? svc.loadModel()
            transcriptionService = svc
        }
    }

    private func setupTranscriptionService() async {
        let provider = AppPreferences.shared.asrProvider
        switch provider {
        case "online":
            let service = AppPreferences.shared.onlineASRService
            switch service {
            case "volcengine":
                let appId = AppPreferences.shared.volcAppId
                let token = AppPreferences.shared.volcAccessToken
                let resourceId = AppPreferences.shared.volcResourceId
                transcriptionService = VolcanoEngineASR(appId: appId, accessToken: token, resourceId: resourceId)
            default:
                let baseURL = URL(string: AppPreferences.shared.asrAPIURL) ?? URL(string: "https://api.openai.com/v1")!
                let apiKey = (try? await KeychainManager.shared.readASRAPIKey()).flatMap { $0.isEmpty ? nil : $0 }
                transcriptionService = OnlineAPITranscription(baseURL: baseURL, apiKey: apiKey, model: AppPreferences.shared.asrModel)
            }
        default:
            setupLocalService()
        }
    }

    private func isModelDownloaded(_ modelId: String) -> Bool {
        ModelDownloadManager.shared.isModelDownloaded(modelId)
    }

    private func engineDescription(for service: TranscriptionService) -> String {
        let serviceName = service.serviceName
        let provider = AppPreferences.shared.asrProvider
        switch provider {
        case "online":
            let onlineService = AppPreferences.shared.onlineASRService
            switch onlineService {
            case "volcengine": return "火山引擎 (流式识别)"
            default: return "OpenAI (Whisper)"
            }
        case "local":
            let modelId = AppPreferences.shared.asrModel
            if modelId.hasPrefix("sense-voice") { return "SenseVoice (\(modelId))" }
            else { return serviceName }
        default:
            return serviceName
        }
    }

    func startTranscription() {
        guard let fileURL = droppedFileURL else { return }

        currentTask = Task {
            // Re-setup service so freshly downloaded models are detected
            await setupTranscriptionService()
            do {
                state = .validating(file: fileURL)

                guard AudioFileValidator.isValid(file: fileURL) else {
                    let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                    let limit = AudioFileValidator.maxFileSize(for: fileURL)
                    if size > limit {
                        let mb = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                        let maxMB = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
                        state = .failed(error: TranscriptionError.transcriptionFailed("文件过大 (\(mb))，上限 \(maxMB)"))
                    } else {
                        state = .failed(error: TranscriptionError.invalidAudioFormat)
                    }
                    return
                }

                let files = [fileURL]
                state = .queued(files: files)

                let duration = await captureDuration(fileURL)

                var allResults: [TranscriptionResult] = []
                var engineDescs: [String] = []

                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    state = .preparing(ASR: transcriptionService?.serviceName ?? "ASR")

                    state = .transcribing(
                        progress: 0,
                        currentFile: index + 1,
                        totalFiles: files.count
                    )

                    guard let service = transcriptionService else {
                        stopProgressTimer()
                        let modelName = AppPreferences.shared.asrModel
                        state = .failed(error: TranscriptionError.transcriptionFailed(
                            "模型 \"\(modelName)\" 尚未下载。\n请前往设置 → ASR → 本地模型 下载后再试。"
                        ))
                        return
                    }

                    let engineDesc = engineDescription(for: service)

                    let ggmlService = transcriptionService as? GGMLTranscriptionService

                    // Start smooth progress timer for local ASR only
                    if ggmlService != nil, let dur = duration {
                        transcriptionDuration = dur
                        targetProgress = 0
                        transcriptionStartTime = Date()
                        startProgressTimer()
                    }

                    ggmlService?.onProgress = { [self] pct in
                        targetProgress = max(targetProgress, pct)
                        if pct >= 1.0 {
                            stopProgressTimer()
                            state = .transcribing(
                                progress: 1.0,
                                currentFile: index + 1,
                                totalFiles: files.count)
                        }
                    }

                    let result = try await service.transcribe(
                        file: file,
                        language: AppPreferences.shared.language
                    )

                    ggmlService?.onProgress = nil
                    stopProgressTimer()

                    allResults.append(result)
                    if engineDescs.isEmpty || engineDescs.count <= index {
                        engineDescs.append(engineDesc)
                    }
                }

                state = .transcribing(progress: 1.0, currentFile: files.count, totalFiles: files.count)

                // Schedule model unload to free memory after idle
                (transcriptionService as? GGMLTranscriptionService)?.scheduleUnload()

                // Save raw transcription to history first
                await saveToHistory(results: allResults, files: files, engineDescs: engineDescs, duration: duration)

                // Configure LLM once for all subsequent calls (refine + summarize)
                let llmConfigured = !AppPreferences.shared.llmBaseURL().isEmpty
                if llmConfigured { await configureLLMClient() }

                // Determine if translation should run
                let translateEnabled = AppPreferences.shared.autoTranslateEnabled && llmConfigured
                let targetLang = AppPreferences.shared.translateTargetLanguage

                // Refine — hand off to a background task so the @MainActor task ends here.
                // Keeping the @MainActor task alive across the LLM call causes macOS
                // to flag the process as "not responding" during long API requests.
                if AppPreferences.shared.autoRefineEnabled && llmConfigured {
                    try? await Task.sleep(nanoseconds: 500_000_000)

                    state = .refining

                    let capturedResults = allResults
                    let capturedFiles = files
                    let capturedEngineDescs = engineDescs
                    let capturedEntryIds = lastHistoryEntryIds
                    let capturedSummaryEnabled = AppPreferences.shared.autoSummaryEnabled
                    let capturedTranslate = translateEnabled
                    let capturedOrigURL = generateSRTFile(results: capturedResults, sourceURL: capturedFiles[0])

                    // Spawn translation as independent parallel task
                    if capturedTranslate {
                        performTranslation(results: capturedResults, files: capturedFiles,
                                           entryIds: capturedEntryIds, targetLang: targetLang,
                                           originalSRTURL: capturedOrigURL)
                    }

                    Task.detached(priority: .userInitiated) { [weak self] in
                        guard let self else { return }
                        do {
                            var refined: [TranscriptionResult] = []
                            for (index, result) in capturedResults.enumerated() {
                                let prompt = AppPreferences.shared.refinePrompt
                                let text = try await LLMClient.shared.refine(
                                    text: result.text,
                                    customPrompt: prompt.isEmpty ? nil : prompt)
                                refined.append(TranscriptionResult(
                                    text: text,
                                    timestamps: result.timestamps,
                                    language: result.language,
                                    confidence: result.confidence))
                                let id = capturedEntryIds.indices.contains(index) ? capturedEntryIds[index] : nil
                                if let id {
                                    await HistoryManager.shared.updateRefinedText(id: id, refinedText: text)
                                }
                            }
                            await MainActor.run { [weak self] in
                                self?.state = .completed(results: refined, files: capturedFiles)
                                self?.saveResults(refined, files: capturedFiles, engineDescs: capturedEngineDescs)
                                if capturedSummaryEnabled { self?.summarize() }
                            }
                        } catch {
                            await MainActor.run { [weak self] in
                                self?.state = .failed(error: error)
                            }
                        }
                    }
                    // @MainActor task ends here — main RunLoop stays free
                    return
                }

                // Always generate original SRT first
                let origURL = generateSRTFile(results: allResults, sourceURL: files[0])

                // Translation-only (no refine)
                if translateEnabled {
                    state = .translating
                    let capturedResults = allResults
                    let capturedFiles = files
                    let capturedEngineDescs = engineDescs
                    performTranslation(results: allResults, files: files,
                                       entryIds: lastHistoryEntryIds, targetLang: targetLang,
                                       originalSRTURL: origURL) { [weak self] in
                        self?.state = .completed(results: capturedResults, files: capturedFiles)
                        self?.saveResults(capturedResults, files: capturedFiles, engineDescs: capturedEngineDescs)
                        if AppPreferences.shared.autoSummaryEnabled { self?.summarize() }
                    }
                } else {
                    state = .completed(results: allResults, files: files)
                    saveResults(allResults, files: files, engineDescs: engineDescs)
                    if AppPreferences.shared.autoSummaryEnabled && llmConfigured { summarize() }
                }

            } catch {
                stopProgressTimer()
                if Task.isCancelled {
                    state = .cancelled
                } else {
                    state = .failed(error: error)
                }
            }
        }
    }

    func cancelTranscription() {
        stopProgressTimer()
        currentTask?.cancel()
        state = .cancelled
    }

    func retryLastTranscription() {
        reset()
        startTranscription()
    }

    func reset() {
        stopProgressTimer()
        droppedFileURL = nil
        state = .idle
        summaryText = nil
        hasRefined = false
    }

    func summarize() {
        guard case .completed(let results, _) = state, !isSummarizing else { return }
        let provider = AppPreferences.shared.llmProvider
        let baseURL = AppPreferences.shared.llmBaseURL()
        guard !baseURL.isEmpty else {
            summaryText = "摘要失败: Base URL 为空 provider=\(provider)"
            return
        }

        let textToSummarize = results.map { $0.text }.joined(separator: "\n\n")
        guard !textToSummarize.isEmpty else { return }

        isSummarizing = true
        summaryText = nil

        summarizeTask = Task {
            do {
                let prompt = AppPreferences.shared.summaryPrompt
                let result = try await Task.detached(priority: .userInitiated) {
                    try await LLMClient.shared.summarize(text: textToSummarize, customPrompt: prompt.isEmpty ? nil : prompt)
                }.value
                summaryText = result
                if let id = lastHistoryEntryIds.first {
                    await HistoryManager.shared.updateSummary(id: id, summaryText: result)
                }
            } catch {
                summaryText = "摘要失败: \(error.localizedDescription)"
            }
            isSummarizing = false
        }
    }

    func refine() {
        guard case .completed(let results, let files) = state, !isRefining, !hasRefined else { return }
        let baseURL = AppPreferences.shared.llmBaseURL()
        guard !baseURL.isEmpty else { return }

        isRefining = true
        hasRefined = true

        refineTask = Task {
            do {
                var refined: [TranscriptionResult] = []
                for (index, result) in results.enumerated() {
                    let prompt = AppPreferences.shared.refinePrompt
                    let text = try await Task.detached(priority: .userInitiated) {
                        try await LLMClient.shared.refine(
                            text: result.text,
                            customPrompt: prompt.isEmpty ? nil : prompt)
                    }.value
                    refined.append(TranscriptionResult(
                        text: text,
                        timestamps: result.timestamps,
                        language: result.language,
                        confidence: result.confidence))
                    let id = lastHistoryEntryIds.indices.contains(index) ? lastHistoryEntryIds[index] : nil
                    if let id {
                        await HistoryManager.shared.updateRefinedText(id: id, refinedText: text)
                    }
                }
                state = .completed(results: refined, files: files)
                saveResults(refined, files: files, engineDescs: [])
            } catch {
                // keep original results on failure
            }
            isRefining = false
        }
    }

    func copyToClipboard() {
        if case .completed(let results, _) = state {
            let text = results.map { $0.text }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @discardableResult
    private func generateSRTFile(results: [TranscriptionResult], sourceURL: URL) -> URL? {
        guard AppPreferences.shared.subtitleExportEnabled else { return nil }
        let allSegments = results.compactMap { $0.segments }.flatMap { $0 }
        guard !allSegments.isEmpty else { return nil }

        let srtText = SubtitleFormatter.toSRT(allSegments)
        guard !srtText.isEmpty else { return nil }

        let resultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Result")
        try? FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let langCode = languageSuffix(AppPreferences.shared.language)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var ts = formatter.string(from: Date())
        ts = ts.replacingOccurrences(of: ":", with: "")
        let srtName = "\(stem)_\(ts).\(langCode).srt"
        let srtURL = resultDir.appendingPathComponent(srtName)

        try? srtText.write(to: srtURL, atomically: true, encoding: .utf8)
        return srtURL
    }

    private func performTranslation(results: [TranscriptionResult], files: [URL],
                                      entryIds: [String?], targetLang: String,
                                      originalSRTURL: URL? = nil,
                                      onComplete: (@MainActor @Sendable () -> Void)? = nil) {
        let capturedResults = results
        let capturedFiles = files
        let capturedEntryIds = entryIds
        let capturedTargetLang = targetLang
        let capturedOrigURL = originalSRTURL
        let translateMode = AppPreferences.shared.translateMode
        let outputMode = AppPreferences.shared.translateOutputMode
        let splitEnabled = AppPreferences.shared.languageSplitEnabled
        let exportEnabled = AppPreferences.shared.subtitleExportEnabled

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                for (index, result) in capturedResults.enumerated() {
                    let rawSource = result.language ?? AppPreferences.shared.language
                    let sourceLang = normalizeLanguage(rawSource)
                    let normalizedTarget = normalizeLanguage(capturedTargetLang)
                    guard sourceLang != normalizedTarget else { continue }

                    let prompt = AppPreferences.shared.translatePrompt
                    let customPrompt = prompt.isEmpty ? nil : prompt
                    var translatedText = ""
                    var translatedSegments: [SubtitleSegment] = []

                    if let segments = result.segments, !segments.isEmpty {
                        if translateMode == .batch {
                            let chunks = chunkSegments(segments)
                            var allRawTexts: [String] = []
                            var allTranslatedSegments: [SubtitleSegment] = []

                            for chunk in chunks {
                                var markedText = ""
                                for (i, seg) in chunk {
                                    markedText += "[SEGMENT \(i + 1)]\n\(seg.text)\n[/SEGMENT \(i + 1)]\n"
                                }
                                let instruction = "Keep the [SEGMENT N] and [/SEGMENT N] markers exactly as-is. Translate only the text between each marker pair — do not merge or reorder segments. Each output segment must correspond 1:1 to the input segment.\n\n"
                                let raw = try await LLMClient.shared.translate(
                                    text: instruction + markedText, targetLanguage: capturedTargetLang,
                                    customPrompt: customPrompt)
                                allRawTexts.append(raw)
                                let parsed = parseTranslatedSegments(raw: raw, original: segments)
                                allTranslatedSegments.append(contentsOf: parsed)
                            }

                            translatedText = allRawTexts.joined(separator: "\n\n")
                            translatedSegments = allTranslatedSegments.sorted { $0.startMs < $1.startMs }
                            if translatedSegments.isEmpty, !allRawTexts.isEmpty {
                                translatedSegments = [SubtitleSegment(
                                    text: allRawTexts.joined(separator: "\n\n"),
                                    startMs: segments.first?.startMs ?? 0,
                                    endMs: segments.last?.endMs ?? 0, language: capturedTargetLang)]
                            }
                        } else {
                            var segResults: [SubtitleSegment] = []
                            var allTexts: [String] = []
                            for seg in segments {
                                let translated = try await LLMClient.shared.translate(
                                    text: seg.text, targetLanguage: capturedTargetLang,
                                    customPrompt: customPrompt)
                                segResults.append(SubtitleSegment(
                                    text: translated, startMs: seg.startMs,
                                    endMs: seg.endMs, language: capturedTargetLang))
                                allTexts.append(translated)
                            }
                            translatedText = allTexts.joined(separator: "\n")
                            translatedSegments = segResults
                        }
                    } else {
                        translatedText = try await LLMClient.shared.translate(
                            text: result.text, targetLanguage: capturedTargetLang,
                            customPrompt: customPrompt)
                    }

                    let id = capturedEntryIds.indices.contains(index) ? capturedEntryIds[index] : nil
                    if let id {
                        await HistoryManager.shared.updateTranslatedText(
                            id: id, translatedText: translatedText,
                            translatedSegments: translatedSegments.isEmpty ? nil : translatedSegments,
                            translateTargetLanguage: capturedTargetLang)
                    }

                    if exportEnabled, !capturedFiles.isEmpty {
                        let sourceURL = capturedFiles.indices.contains(index) ? capturedFiles[index] : capturedFiles[0]
                        await generateTranslatedSRT(
                            original: result.segments ?? [],
                            translated: translatedSegments,
                            sourceURL: sourceURL, targetLang: capturedTargetLang,
                            outputMode: outputMode, splitEnabled: splitEnabled,
                            originalSRTURL: capturedOrigURL)
                    }
                }
            } catch {
                await Logger.shared.error("Translation failed: \(error.localizedDescription)")
            }
            if let onComplete { await onComplete() }
        }
    }

    private nonisolated let maxSegmentsPerChunk = 80

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

    /// Parse batch translation response back to segments by matching [SEGMENT N] markers.
    private nonisolated func parseTranslatedSegments(raw: String, original: [SubtitleSegment]) -> [SubtitleSegment] {
        var result: [SubtitleSegment] = []
        for (i, seg) in original.enumerated() {
            let openMarker = "[SEGMENT \(i + 1)]"
            let closeMarker = "[/SEGMENT \(i + 1)]"
            guard let openRange = raw.range(of: openMarker),
                  let closeRange = raw.range(of: closeMarker),
                  openRange.upperBound < closeRange.lowerBound else { continue }
            var startIdx = openRange.upperBound
            // Skip whitespace/newlines right after the open marker
            while startIdx < closeRange.lowerBound, raw[startIdx].isNewline || raw[startIdx].isWhitespace {
                startIdx = raw.index(after: startIdx)
            }
            var endIdx = closeRange.lowerBound
            // Trim trailing whitespace/newlines before the close marker
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

    /// Generate translated SRT file(s) based on output mode and language split settings.
    private func generateTranslatedSRT(original: [SubtitleSegment], translated: [SubtitleSegment],
                                        sourceURL: URL, targetLang: String,
                                        outputMode: TranslateOutputMode, splitEnabled: Bool,
                                        originalSRTURL: URL? = nil) {
        let resultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Result")
        try? FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let langCode = languageSuffix(targetLang)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var ts = formatter.string(from: Date())
        ts = ts.replacingOccurrences(of: ":", with: "")

        // Language split: group segments by language with index tracking,
        // then generate per-language SRT files (with translations when available).
        if splitEnabled && !original.isEmpty {
            var groups: [(lang: String, orig: [SubtitleSegment], trans: [SubtitleSegment])] = []
            var groupMap: [String: (orig: [SubtitleSegment], trans: [SubtitleSegment])] = [:]
            for (i, seg) in original.enumerated() {
                let lang = seg.language ?? ""
                if groupMap[lang] == nil { groupMap[lang] = ([], []) }
                groupMap[lang]!.orig.append(seg)
                if i < translated.count {
                    groupMap[lang]!.trans.append(translated[i])
                }
            }
            // Preserve original order of language appearance
            var seen: Set<String> = []
            for seg in original {
                let lang = seg.language ?? ""
                if seen.insert(lang).inserted, let g = groupMap[lang] {
                    groups.append((lang, g.orig, g.trans))
                }
            }

            for (lang, groupOrig, groupTrans) in groups {
                let groupLang = lang.isEmpty ? langCode : languageSuffix(lang)
                switch outputMode {
                case .bilingual:
                    let srtText = groupTrans.isEmpty
                        ? SubtitleFormatter.toSRT(groupOrig)
                        : SubtitleFormatter.toSRTBilingual(original: groupOrig, translated: groupTrans)
                    guard !srtText.isEmpty else { continue }
                    let srtName = "\(stem)_\(ts).\(groupLang).srt"
                    // Single language: overwrite original; multi-language: separate per-language files
                    let srtURL: URL
                    if let origURL = originalSRTURL, groups.count == 1 {
                        srtURL = origURL
                    } else {
                        srtURL = resultDir.appendingPathComponent(srtName)
                    }
                    try? srtText.write(to: srtURL, atomically: true, encoding: .utf8)
                case .translationOnly:
                    // Only write per-language original when multiple languages detected;
                    // for single-language audio the unfiltered original from generateSRTFile suffices.
                    if groups.count > 1 {
                        let origSRT = SubtitleFormatter.toSRT(groupOrig)
                        if !origSRT.isEmpty {
                            let origName = "\(stem)_\(ts).\(groupLang).srt"
                            try? origSRT.write(to: resultDir.appendingPathComponent(origName), atomically: true, encoding: .utf8)
                        }
                    }
                    if !groupTrans.isEmpty {
                        let transSRT = SubtitleFormatter.toSRT(groupTrans)
                        if !transSRT.isEmpty {
                            let transName = "\(stem)_\(ts).\(groupLang)_\(langCode).srt"
                            try? transSRT.write(to: resultDir.appendingPathComponent(transName), atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            return
        }

        // No language split — single SRT output
        switch outputMode {
        case .bilingual:
            let srtText = SubtitleFormatter.toSRTBilingual(original: original, translated: translated)
            guard !srtText.isEmpty else { return }
            // Overwrite the original SRT file with bilingual version
            let srtURL = originalSRTURL ?? resultDir.appendingPathComponent("\(stem)_\(ts).\(langCode).srt")
            try? srtText.write(to: srtURL, atomically: true, encoding: .utf8)

        case .translationOnly:
            // Original SRT already exists from generateSRTFile — only write new translation file
            let transSRT = SubtitleFormatter.toSRT(translated)
            if !transSRT.isEmpty {
                let transName = "\(stem)_\(ts).\(langCode).srt"
                try? transSRT.write(to: resultDir.appendingPathComponent(transName), atomically: true, encoding: .utf8)
            }
        }
    }

    /// Normalize language codes so variants like "zh" and "zh-CN" are treated as equal.
    private nonisolated func normalizeLanguage(_ lang: String?) -> String {
        guard let lang = lang?.lowercased(), !lang.isEmpty else { return "und" }
        if lang.hasPrefix("zh-cn") || lang == "zh" { return "zh-CN" }
        if lang.hasPrefix("zh-tw") || lang.hasPrefix("zh-hk") { return "zh-TW" }
        if lang.hasPrefix("en") { return "en" }
        if lang.hasPrefix("ja") { return "ja" }
        if lang.hasPrefix("ko") { return "ko" }
        return lang
    }

    /// Map transcription language string to subtitle-standard short filename suffix.
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

    private func saveResults(_ results: [TranscriptionResult], files: [URL], engineDescs: [String]) {
        let resultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Result")
        try? FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())

        for (index, result) in results.enumerated() {
            let fileName = files.indices.contains(index)
                ? files[index].deletingPathExtension().lastPathComponent
                : "unknown"
            let outputFile = resultDir.appendingPathComponent("\(timestamp)_\(fileName).txt")

            let engineInfo = engineDescs.indices.contains(index) ? engineDescs[index] : ""

            let header = """
            VoiceGum 转写结果
            引擎: \(engineInfo)
            时间: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))
            文件: \(files.indices.contains(index) ? files[index].lastPathComponent : "unknown")
            语言: \(result.language ?? "auto")
            置信度: \(result.confidence.map { String(format: "%.2f", $0) } ?? "N/A")
            ---

            """
            try? (header + result.text).write(to: outputFile, atomically: true, encoding: .utf8)
        }
    }

    private func saveToHistory(results: [TranscriptionResult], files: [URL], engineDescs: [String], duration: TimeInterval?) async {
        guard AppPreferences.shared.autoSaveHistory else { return }
        lastHistoryEntryIds = []
        for (index, result) in results.enumerated() {
            let fileName = files.indices.contains(index)
                ? files[index].lastPathComponent
                : "unknown"
            let engineDesc = engineDescs.indices.contains(index) ? engineDescs[index] : ""
            let entry = HistoryEntry(
                sourceFileName: fileName,
                timestamp: Date(),
                engineDescription: engineDesc,
                language: result.language,
                duration: duration,
                rawText: result.text
            )
            lastHistoryEntryIds.append(entry.id)
            await HistoryManager.shared.add(entry)
        }
    }

    private func configureLLMClient() async {
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
        guard let baseURL else { return }
        let apiKey = AppPreferences.shared.llmAPIKey()
        await LLMClient.shared.configure(provider: provider, baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey, model: AppPreferences.shared.llmModel())
    }

    /// Present NSSavePanel for manual SRT subtitle export from a history entry.
    static func exportSubtitles(entry: HistoryEntry) {
        guard let segments = entry.segments, !segments.isEmpty else { return }

        let srtContent = SubtitleFormatter.toSRT(segments)
        guard !srtContent.isEmpty else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = (entry.sourceFileName as NSString).deletingPathExtension + ".srt"
        savePanel.title = String(localized: "导出字幕")
        savePanel.message = String(localized: "选择字幕文件的保存位置")

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try srtContent.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "字幕导出失败")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "确定"))
                alert.runModal()
            }
        }
    }

    private func captureDuration(_ fileURL: URL) async -> TimeInterval? {
        let asset = AVAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickProgress()
            }
        }
    }

    private func stopProgressTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tickProgress() {
        guard let start = transcriptionStartTime,
              let duration = transcriptionDuration,
              duration > 0 else { return }

        let elapsed = Date().timeIntervalSince(start)
        let estimatedTotal = max(duration * 0.05, 1.0)
        let elapsedRatio = min(elapsed / estimatedTotal, 0.99)

        guard case .transcribing(let current, let file, let total) = state else { return }

        let step = 0.02
        let smoothed = max(current + step, elapsedRatio)
        let displayProgress = min(smoothed, targetProgress + 0.03, 0.99)

        if displayProgress > current {
            state = .transcribing(progress: displayProgress, currentFile: file, totalFiles: total)
        }
    }

}