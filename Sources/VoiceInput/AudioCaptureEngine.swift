import AVFoundation
import os

final class AudioCaptureEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var _rms: Float = 0
    private let rmsLock = os_unfair_lock_t.allocate(capacity: 1)

    var rmsLevel: Float {
        os_unfair_lock_lock(rmsLock); defer { os_unfair_lock_unlock(rmsLock) }; return _rms
    }

    nonisolated(unsafe) var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false

    deinit { stop(); rmsLock.deallocate() }

    func start() throws {
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let hwFmt = input.inputFormat(forBus: 0)

        guard hwFmt.sampleRate > 0, hwFmt.channelCount > 0 else {
            throw AudioCaptureError.noAudioInput
        }

        eng.connect(input, to: eng.mainMixerNode, format: hwFmt)
        eng.mainMixerNode.outputVolume = 0

        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self, let cd = buf.floatChannelData else { return }
            let ch = cd[0]; let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { let s = ch[i]; sum += s * s }
            os_unfair_lock_lock(self.rmsLock)
            self._rms = n > 0 ? sqrt(sum / Float(n)) : 0
            os_unfair_lock_unlock(self.rmsLock)
            self.onAudioBuffer?(buf)
        }

        eng.prepare()
        try eng.start()
        engine = eng
        isRunning = true
    }

    func stop() {
        guard let eng = engine, isRunning else { return }
        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        engine = nil; isRunning = false
        os_unfair_lock_lock(rmsLock); _rms = 0; os_unfair_lock_unlock(rmsLock)
    }

    enum AudioCaptureError: LocalizedError {
        case noAudioInput
        var errorDescription: String? { "未检测到麦克风" }
    }
}
