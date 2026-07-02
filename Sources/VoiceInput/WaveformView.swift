import SwiftUI

/// Five-bar waveform driven by real-time RMS level.
struct WaveformView: View {
    @ObservedObject var model: OverlayViewModel

    private let weights: [Float] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let barW: CGFloat = 4
    private let spacing: CGFloat = 4
    private let maxH: CGFloat = 32
    private let minH: CGFloat = 2
    private let attack: Float = 0.40
    private let release: Float = 0.15

    @State private var heights: [CGFloat] = [2, 2, 2, 2, 2]

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: barW / 2)
                    .fill(.white.opacity(0.9))
                    .frame(width: barW, height: heights[i])
            }
        }
        .frame(width: 44, height: 32)
        .onChange(of: model.rmsLevel) { _, rms in
            let norm = min(1.0, rms * 30.0)
            for i in 0..<5 {
                var t = CGFloat(norm * weights[i]) * maxH
                t += CGFloat(Float.random(in: -0.04...0.04) * Float(t))
                t = max(minH, min(maxH, t))
                let cur = heights[i]
                if t > cur { heights[i] = cur + (t - cur) * CGFloat(attack) }
                else { heights[i] = cur + (t - cur) * CGFloat(release) }
            }
        }
    }
}
