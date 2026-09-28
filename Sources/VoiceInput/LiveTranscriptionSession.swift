@preconcurrency import AVFoundation
import Foundation

/// Drives the segment-level live preview for the local ASR engines.
///
/// Audio in → resample to 16 kHz → split on silence → decode one utterance → report text.
/// The session never injects text and never touches the UI directly: callers consume the
/// `onText` callback and the `finish()` result. Failures only cost preview text — the final
/// decode runs the offline pipeline independently.
actor LiveTranscriptionSession {

    typealias Decoder = @Sendable (_ samples: [Float], _ language: String) async throws -> String

    private let decoder: Decoder
    private let language: String
    private let onText: @Sendable @MainActor (String) -> Void

    private let resampler = StreamingAudioResampler()
    private var segmenter = StreamingSegmenter()
    private var stream: [Float] = []
    private var text = ""
    private var inFlight: Task<Void, Never>?
    private var pendingSamples: [Float]?

    init(
        language: String,
        decoder: @escaping Decoder,
        onText: @escaping @Sendable @MainActor (String) -> Void
    ) {
        self.language = language
        self.decoder = decoder
        self.onText = onText
    }

    /// Feeds one capture buffer. Decoding runs off the caller's thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let samples = resampler.resample(buffer)
        guard !samples.isEmpty else { return }
        stream.append(contentsOf: samples)

        for segment in segmenter.feed(samples) {
            enqueue(segment)
        }
    }

    /// Ends the stream: closes the open segment, waits for in-flight decodes, returns the preview text.
    func finish() async -> String {
        if let segment = segmenter.flush() {
            enqueue(segment)
        }
        while let task = inFlight {
            await task.value
        }
        return text
    }

    /// Abandons the session. In-flight decoding is not awaited — the caller must not start another
    /// decode on the same model handle before it returns.
    func cancel() {
        pendingSamples = nil
        inFlight?.cancel()
        inFlight = nil
        segmenter.reset()
        stream.removeAll()
        text = ""
    }

    // MARK: - Private

    private func enqueue(_ segment: StreamingSegmenter.Segment) {
        let samples = Array(stream[segment.startSample..<segment.endSample])
        guard !samples.isEmpty else { return }

        if inFlight == nil {
            startDecode(samples)
        } else {
            // Preview only: keep the freshest segment, drop the ones we could not keep up with.
            pendingSamples = samples
        }
    }

    private func startDecode(_ samples: [Float]) {
        let decoder = self.decoder
        let language = self.language
        inFlight = Task { [weak self] in
            let decoded = (try? await decoder(samples, language)) ?? ""
            guard !Task.isCancelled else { return }
            await self?.didFinishDecode(decoded)
        }
    }

    private func didFinishDecode(_ decoded: String) async {
        inFlight = nil
        if !decoded.isEmpty {
            // Same separator the offline pipeline uses when it joins segments.
            text = text.isEmpty ? decoded : text + " " + decoded
            let current = text
            await onText(current)
        }
        if let next = pendingSamples {
            pendingSamples = nil
            startDecode(next)
        }
    }
}
