// funasr-nano-vad.cpp — Energy-based voice activity detection for FunASR-Nano
#include "funasr-nano.h"
#include <algorithm>
#include <cmath>
#include <vector>

// RMS energy of a signal frame
static float frame_rms(const float * pcm, int n) {
    double sum = 0;
    for (int i = 0; i < n; i++) sum += (double)pcm[i] * pcm[i];
    return (float)sqrt(sum / n);
}

std::vector<NanoVADSegment> nano_vad_detect(const std::vector<float> & pcm, int sample_rate) {
    const int frame_ms = 25, step_ms = 10;
    const int frame_len = sample_rate * frame_ms / 1000;   // 400 @ 16kHz
    const int step_len = sample_rate * step_ms / 1000;     // 160 @ 16kHz
    const float min_speech_s = 0.3f;
    const float min_silence_s = 0.5f;
    const float pad_s = 0.1f;

    int n_samples = (int)pcm.size();
    if (n_samples < frame_len) return {};

    // Compute per-frame energy
    int n_frames = (n_samples - frame_len) / step_len + 1;
    std::vector<float> energy(n_frames);
    float max_energy = 0;
    for (int i = 0; i < n_frames; i++) {
        energy[i] = frame_rms(pcm.data() + i * step_len, frame_len);
        if (energy[i] > max_energy) max_energy = energy[i];
    }

    if (max_energy < 1e-10f) return {}; // silence

    // Adaptive threshold: 3% of max energy, clamped to reasonable range
    float thresh = max_energy * 0.03f;

    // Find speech segments
    std::vector<NanoVADSegment> segments;
    bool in_speech = false;
    int seg_start = 0;

    for (int i = 0; i < n_frames; i++) {
        bool speech = energy[i] > thresh;
        if (speech && !in_speech) {
            seg_start = i;
            in_speech = true;
        } else if (!speech && in_speech) {
            int silence_frames = 1;
            while (i + silence_frames < n_frames && energy[i + silence_frames] <= thresh)
                silence_frames++;
            if (silence_frames * step_ms >= min_silence_s * 1000) {
                int end_frame = i;
                float dur = (end_frame - seg_start) * step_ms / 1000.0f;
                if (dur >= min_speech_s) {
                    int start_s = std::max(0, seg_start * step_len - (int)(pad_s * sample_rate));
                    int end_s = std::min(n_samples, (end_frame * step_len + frame_len) + (int)(pad_s * sample_rate));
                    segments.push_back({start_s, end_s});
                }
                in_speech = false;
            }
            i += silence_frames - 1;
        }
    }

    // Final segment
    if (in_speech) {
        float dur = (n_frames - seg_start) * step_ms / 1000.0f;
        if (dur >= min_speech_s) {
            int start_s = std::max(0, seg_start * step_len - (int)(pad_s * sample_rate));
            segments.push_back({start_s, n_samples});
        }
    }

    // Merge adjacent segments separated by short gaps
    if (segments.size() > 1) {
        std::vector<NanoVADSegment> merged;
        merged.push_back(segments[0]);
        for (size_t i = 1; i < segments.size(); i++) {
            int gap = segments[i].start_sample - merged.back().end_sample;
            if (gap < sample_rate * 0.8f) { // merge if gap < 0.8s
                merged.back().end_sample = segments[i].end_sample;
            } else {
                merged.push_back(segments[i]);
            }
        }
        segments = std::move(merged);
    }

    return segments;
}
