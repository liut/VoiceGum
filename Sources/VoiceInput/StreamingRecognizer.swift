import Speech
@preconcurrency import AVFoundation

/// Wraps SFSpeechRecognizer for streaming transcription.
/// Uses final class (not actor) to avoid Swift 6 false-positive data-race warnings
/// caused by the ObjC resultHandler lacking @Sendable.
final class StreamingRecognizer: @unchecked Sendable {

    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var accumulatedPartial: String = ""

    /// Called with partial transcription results (on MainActor).
    var onPartialResult: (@MainActor (String) -> Void)?

    /// Called with the final transcription result (on MainActor).
    var onFinalResult: (@MainActor (String) -> Void)?

    /// Called when an error occurs (on MainActor).
    var onError: (@MainActor (Error) -> Void)?

    static func isLanguageSupported(_ language: String) -> Bool {
        resolveLocale(for: language) != nil
    }

    static func resolveLocale(for language: String) -> Locale? {
        if language == "auto" {
            guard let sysLang = Locale.preferredLanguages.first else { return nil }
            return resolveLocale(for: sysLang)
        }
        let requested = Locale(identifier: language)
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(requested) { return requested }
        // System languages such as "zh-Hans-CA" are absent from supportedLocales while "zh-CN" is
        // present, so match on language/script/region instead of dropping to the offline engine.
        return supported
            .filter { $0.language.languageCode == requested.language.languageCode }
            .max { matchScore($0, requested) < matchScore($1, requested) }
    }

    private static func matchScore(_ supported: Locale, _ requested: Locale) -> Int {
        var score = 0
        if let script = requested.language.script, supported.language.script == script { score += 2 }
        if let region = requested.language.region, supported.language.region == region { score += 1 }
        return score
    }

    init?(locale: Locale) {
        guard let rec = SFSpeechRecognizer(locale: locale) else { return nil }
        recognizer = rec
        recognizer.queue = OperationQueue()
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Start a new recognition task.
    func start() throws {
        task?.cancel()
        task = nil
        request = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if let error = error {
                Task { @MainActor in self.onError?(error) }
                return
            }

            guard let result = result else { return }

            let rawText = result.bestTranscription.formattedString
            let text = self.accumulatedPartial.isEmpty
                ? rawText
                : self.accumulatedPartial + " " + rawText

            if result.isFinal {
                self.accumulatedPartial = ""
                Task { @MainActor in self.onFinalResult?(text) }
            } else {
                Task { @MainActor in self.onPartialResult?(text) }
            }
        }
    }

    /// Append an audio buffer to the active recognition request.
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Signal end of audio input and finish recognition.
    func finish() {
        request?.endAudio()
        task?.finish()
    }

    /// Immediately cancel recognition. No final result.
    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        accumulatedPartial = ""
    }
}
