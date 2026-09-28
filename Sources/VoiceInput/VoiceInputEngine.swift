import AppKit
@preconcurrency import AVFoundation
import Speech
import VoiceGumPreferences
import VoiceGumServices

// MARK: - State types

enum VoiceInputState {
    case idle, recording, recognizing, injecting, done, cancelled
    case error(VoiceInputError)
}

enum VoiceInputError {
    case noAudioInput, speechRecognitionUnavailable, modelNotDownloaded, microphonePermissionDenied
    case engineFailure(String)
}

/// Which recognizer is running the current session. The overlay colors its waveform by engine so
/// the system recognizer and the offline model are visually distinguishable.
public enum VoiceInputASREngine: Equatable, Sendable {
    case systemSpeech
    case offlineModel
}

extension VoiceInputError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noAudioInput: "未检测到麦克风"
        case .speechRecognitionUnavailable: "语音识别不可用"
        case .modelNotDownloaded: "离线模型未下载，请前往设置下载"
        case .microphonePermissionDenied: "麦克风权限未授权"
        case .engineFailure(let msg): msg
        }
    }
}

// MARK: - Actor

actor VoiceInputEngine {

    // MARK: Outputs

    nonisolated(unsafe) private var _onStateChange: (@MainActor (VoiceInputState) -> Void)?
    nonisolated(unsafe) private var _onPartialText: (@MainActor (String) -> Void)?
    nonisolated(unsafe) private var _onRMSLevel: (@MainActor (Float) -> Void)?
    nonisolated(unsafe) private var _onEngineChange: (@MainActor (VoiceInputASREngine) -> Void)?

    func setStateChangeHandler(_ h: @Sendable @escaping @MainActor (VoiceInputState) -> Void) { _onStateChange = h }
    func setPartialTextHandler(_ h: @Sendable @escaping @MainActor (String) -> Void) { _onPartialText = h }
    func setRMSLevelHandler(_ h: @Sendable @escaping @MainActor (Float) -> Void) { _onRMSLevel = h }
    func setEngineChangeHandler(_ h: @Sendable @escaping @MainActor (VoiceInputASREngine) -> Void) { _onEngineChange = h }

    // MARK: State

    private var state = VoiceInputState.idle
    private var targetApp: NSRunningApplication?
    private var isFunASRFallback = false
    private var accumulatedBuffers: [AVAudioPCMBuffer] = []
    private var bestLocalModel: (any TranscriptionService)?
    private var audioCapture: AudioCaptureEngine?
    private var recognizer: StreamingRecognizer?
    private var rmsTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var stallWatchdogTask: Task<Void, Never>?
    private let maxRecordingDuration: TimeInterval = 60
    private let recognitionStallTimeout: TimeInterval = 15

    // MARK: - Public API

    func startRecording() async {
        switch state {
        case .idle, .done, .cancelled, .error: break
        default: return
        }
        targetApp = NSWorkspace.shared.frontmostApplication

        if StreamingRecognizer.authorizationStatus == .notDetermined {
            _ = await StreamingRecognizer.requestAuthorization()
        }

        let language = AppPreferences.shared.language
        let isAuth = StreamingRecognizer.authorizationStatus == .authorized
        let locale = StreamingRecognizer.resolveLocale(for: language)
        isFunASRFallback = !(isAuth && locale != nil)

        let capture = AudioCaptureEngine()
        do { try capture.start() }
        catch { await emit(.error(.microphonePermissionDenied)); return }
        audioCapture = capture
        state = .recording
        await emit(.recording)
        startRMSPolling()
        startTimeout()

        if isFunASRFallback { await startFunASR(capture) }
        else { await startSFSpeech(capture, locale: locale!) }
    }

    func stopRecording() async {
        switch state {
        case .idle, .done, .cancelled: return
        case .error:
            cleanup(); state = .cancelled; await emit(.cancelled)
        case .recording where isFunASRFallback:
            state = .recognizing; await emit(.recognizing)
            startStallWatchdog()
            await processFunASR()
        case .recording:
            recognizer?.finish()
            startStallWatchdog()
        default: break
        }
    }

    func cancelRecording() async {
        audioCapture?.stop(); recognizer?.cancel(); recognizer = nil
        accumulatedBuffers.removeAll(); stopRMSPolling(); stopTimeout(); stopStallWatchdog(); audioCapture = nil
        state = .cancelled; await emit(.cancelled)
    }

    // MARK: - SFSpeech path

    private func startSFSpeech(_ capture: AudioCaptureEngine, locale: Locale) async {
        guard let rec = StreamingRecognizer(locale: locale) else {
            await switchToFunASR(capture); return
        }
        recognizer = rec
        rec.onPartialResult = { [weak self] t in
            Task { @MainActor in await self?._onPartialText?(t) }
        }
        rec.onFinalResult = { [weak self] t in
            Task { await self?.handleFinalText(t) }
        }
        rec.onError = { [weak self] _ in
            Task { await self?.handleRecognitionError() }
        }
        do { try rec.start() }
        catch { await switchToFunASR(capture); return }
        capture.onAudioBuffer = { [weak rec] b in rec?.append(b) }
        await emitEngine(.systemSpeech)
    }

    private func switchToFunASR(_ capture: AudioCaptureEngine) async {
        isFunASRFallback = true
        await startFunASR(capture)
    }

    // MARK: - FunASR path

    private func startFunASR(_ capture: AudioCaptureEngine) async {
        guard let (service, _) = findBestLocalModel() else {
            capture.stop(); audioCapture = nil; stopRMSPolling()
            state = .error(.modelNotDownloaded); await emit(state)
            return
        }
        bestLocalModel = service
        accumulatedBuffers = []
        capture.onAudioBuffer = { [weak self] b in Task { await self?.accumulate(b) } }
        await emitEngine(.offlineModel)
    }

    private func accumulate(_ b: AVAudioPCMBuffer) { accumulatedBuffers.append(b) }

    private func processFunASR() async {
        guard let url = writeWAV() else {
            cleanup(); state = .error(.engineFailure("保存录音失败")); await emit(state); return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let svc = bestLocalModel else {
            cleanup(); state = .error(.modelNotDownloaded); await emit(state); return
        }
        do {
            let result = try await svc.transcribe(file: url, language: AppPreferences.shared.language)
        await handleFinalText(result.text)
        } catch {
            cleanup(); state = .error(.engineFailure(error.localizedDescription)); await emit(state)
        }
    }

    // MARK: - Finalization

    private func handleFinalText(_ text: String) async {
        guard !text.isEmpty else { cleanup(); state = .done; await emit(.done); return }
        // Pass text + target to ViewModel for MainActor injection (avoids MainActor.run deadlock)
        await emit(.injecting)
        await MainActor.run { [text, app = targetApp] in
            NotificationCenter.default.post(name: .voiceInputInjectText, object: nil, userInfo: ["text": text, "targetApp": app as Any])
        }
        cleanup(); state = .done; await emit(.done)
    }

    private func handleRecognitionError() async {
        cleanup(); state = .error(.speechRecognitionUnavailable); await emit(state)
    }

    private func cleanup() {
        audioCapture?.stop(); audioCapture = nil; recognizer = nil
        accumulatedBuffers.removeAll(); stopRMSPolling(); stopTimeout(); stopStallWatchdog()
    }

    // MARK: - WAV

    private func writeWAV() -> URL? {
        guard !accumulatedBuffers.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicegum_\(AppPreferences.makeTimestamp()).wav")
        let total = accumulatedBuffers.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0 else { return nil }
        var samples = [Int16](repeating: 0, count: total)
        var i = 0
        for b in accumulatedBuffers {
            guard let d = b.floatChannelData?[0] else { continue }
            for j in 0..<Int(b.frameLength) { let v = max(-1, min(1, d[j])); samples[i] = Int16(v * Float(Int16.max)); i += 1 }
        }
        let sr = Int32(accumulatedBuffers[0].format.sampleRate)
        let ds = Int32(total * 2)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? fh.close() }
        writeWAVHeader(fh, sr: sr, ds: ds)
        fh.write(Data(bytes: samples, count: Int(ds)))
        return url
    }

    private func writeWAVHeader(_ fh: FileHandle, sr: Int32, ds: Int32) {
        let br = sr * 2; let ba = Int16(2); let bp = Int16(16)
        var h = Data()
        h.append("RIFF".data(using: .ascii)!); h.append(contentsOf: withUnsafeBytes(of: (ds + 36).littleEndian, Array.init))
        h.append("WAVE".data(using: .ascii)!); h.append("fmt ".data(using: .ascii)!)
        h.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: sr.littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: br.littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: ba.littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: bp.littleEndian, Array.init))
        h.append("data".data(using: .ascii)!); h.append(contentsOf: withUnsafeBytes(of: ds.littleEndian, Array.init))
        fh.write(h)
    }

    // MARK: - Model discovery

    private func findBestLocalModel() -> (service: any TranscriptionService, language: String)? {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceGum/Models")

        let nanoDir = modelsDir.appendingPathComponent("funasr-nano")
        let nanoFiles = (try? FileManager.default.contentsOfDirectory(atPath: nanoDir.path)) ?? []
        if nanoFiles.contains(where: { $0.hasSuffix(".gguf") }) {
            return (FunASRNanoTranscriptionService(modelId: "funasr-nano"), AppPreferences.shared.language)
        }

        let svDirs = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        for dirName in svDirs {
            if dirName.hasPrefix("sense-voice") {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.appendingPathComponent(dirName).path)) ?? []
                if files.contains(where: { $0.hasSuffix(".gguf") }) {
                    return (FunASRTranscriptionService(modelId: dirName), AppPreferences.shared.language)
                }
            }
        }

        return nil
    }

    // MARK: - RMS Polling

    private func startRMSPolling() {
        rmsTask?.cancel()
        rmsTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0
            while !Task.isCancelled {
                if let c = await audioCapture {
                    tick += 1
                    if tick % 3 == 0 { await self._onRMSLevel?(c.rmsLevel) }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopRMSPolling() { rmsTask?.cancel(); rmsTask = nil }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            await self.stopRecording()
        }
    }

    private func stopTimeout() { timeoutTask?.cancel(); timeoutTask = nil }

    /// Recognition normally finishes within a second or two. This watchdog only fires when it
    /// stalls, so the capsule cannot stay on screen while nothing is recording or recognizing.
    private func startStallWatchdog() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.recognitionStallTimeout))
            guard !Task.isCancelled else { return }
            await self.finishStalledRecognition()
        }
    }

    private func stopStallWatchdog() { stallWatchdogTask?.cancel(); stallWatchdogTask = nil }

    private func finishStalledRecognition() async {
        switch state {
        case .recording, .recognizing: break
        default: return
        }
        cleanup()
        state = .cancelled
        await Logger.shared.warn("语音输入识别超时，强制收尾")
        await emit(.cancelled)
    }

    private func emit(_ s: VoiceInputState) async {
        await MainActor.run { self._onStateChange?(s) }
    }

    private func emitEngine(_ engine: VoiceInputASREngine) async {
        await MainActor.run { self._onEngineChange?(engine) }
    }
}
