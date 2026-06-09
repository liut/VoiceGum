// sense_voice_adapter.cpp — Bridge between our C API and SenseVoice.cpp ggml code
#include "sense-voice.h"
#include "common.h"
#include "silero-vad.h"
#include "asr_engine.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct sense_voice_wrapper {
    sense_voice_context * ctx = nullptr;
    sense_voice_context_params params;
    bool loaded = false;
};

struct progress_bridge {
    asr_progress_fn fn;
    void *data;
};

static void bridge_progress_callback(
    sense_voice_context * /*ctx*/,
    sense_voice_state * /*state*/,
    int progress,
    void *user_data)
{
    auto *bridge = static_cast<progress_bridge *>(user_data);
    if (bridge && bridge->fn) {
        bridge->fn(progress / 100.0f, bridge->data);
    }
}

extern "C" {

void * sv_load_model(const char * gguf_path, int use_gpu) {
    auto * w = new sense_voice_wrapper();
    w->params = sense_voice_context_default_params();
    w->params.use_gpu = use_gpu != 0;
    w->params.flash_attn = false;

    w->ctx = sense_voice_small_init_from_file_with_params(gguf_path, w->params);
    if (!w->ctx) {
        fprintf(stderr, "sv: failed to load model %s\n", gguf_path);
        delete w;
        return nullptr;
    }
    w->loaded = true;
    return w;
}

void sv_free(void * handle) {
    if (!handle) return;
    auto * w = (sense_voice_wrapper *)handle;
    if (w->ctx) sense_voice_free(w->ctx);
    delete w;
}

static bool load_wav_samples(const char * path, std::vector<double> & pcmf64, int & sample_rate) {
    return load_wav_file(path, &sample_rate, pcmf64);
}

char * sv_transcribe(
    void * handle,
    const char * wav_path,
    const char * language,
    int n_threads,
    asr_progress_fn on_progress,
    void * progress_userdata)
{
    auto * w = (sense_voice_wrapper *)handle;
    if (!w || !w->loaded) return nullptr;

    std::vector<double> pcmf64;
    int sample_rate = 16000;
    if (!load_wav_samples(wav_path, pcmf64, sample_rate)) {
        fprintf(stderr, "sv: failed to load WAV %s\n", wav_path);
        return nullptr;
    }

    auto & ctx = w->ctx;
    ctx->language_id = sense_voice_lang_id(language);

    sense_voice_full_params wparams = sense_voice_full_default_params(SENSE_VOICE_SAMPLING_GREEDY);
    wparams.n_threads = n_threads;
    wparams.print_progress = false;
    wparams.print_timestamps = false;
    wparams.language = language;

    progress_bridge bridge = { on_progress, progress_userdata };
    if (on_progress) {
        wparams.progress_callback = bridge_progress_callback;
        wparams.progress_callback_user_data = &bridge;
    }

    // ── VAD + concatenated ASR ──
    // VAD locates speech regions and strips long silences, then we
    // concatenate segments into one continuous utterance for a single
    // ASR call. This preserves full cross-segment encoder context
    // (unlike per-segment transcription) while still removing silence.

    const size_t total_samples = pcmf64.size();

    // VAD model expects float samples normalized to [-1, 1], but the WAV loader
    // uses scale=1.0 (raw int16 range). ASR feature extractor has its own CMVN
    // normalization, so we keep original pcmf64 for ASR and normalize a copy for VAD.
    std::vector<float> pcmf32(total_samples);
    for (size_t i = 0; i < total_samples; i++) {
        pcmf32[i] = (float)(pcmf64[i] / 32768.0);
    }

    silero_vad_reset_state(*ctx->state);
    silero_vad_with_state(*ctx, *ctx->state, pcmf32, n_threads);

    auto segments = std::move(ctx->state->result_all);
    ctx->state->result_all.clear();

    std::string text;

    // Batch segments into ~30s chunks for ASR.
    // Concatenating adjacent segments preserves local encoder context, but
    // the 50-layer self-attention degrades beyond ~30s. Batching keeps each
    // ASR call within the effective attention window.
    const float MAX_CHUNK_SECONDS = 30.0f;
    const size_t max_chunk_samples = (size_t)(SENSE_VOICE_SAMPLE_RATE * MAX_CHUNK_SECONDS);
    const size_t silence_samples = (size_t)(SENSE_VOICE_SAMPLE_RATE * 0.2); // 200ms

    auto transcribe_batch = [&](std::vector<double> &batch) -> bool {
        if (batch.empty()) return true;
        ctx->state->result_all.clear();
        ctx->state->segmentIDs.clear();
        ctx->state->duration = (float)batch.size() / SENSE_VOICE_SAMPLE_RATE;

        int ret = sense_voice_full_parallel(ctx, wparams, batch, (int)batch.size(), 1);
        if (ret != 0) {
            SENSE_VOICE_LOG_ERROR("%s: batch transcription failed, ret=%d\n", __func__, ret);
            return false;
        }

        auto &ids = ctx->state->ids;
        for (size_t i = 4; i < ids.size(); i++) {
            if (i > 4 && ids[i-1] == ids[i]) continue;
            if (ids[i]) text += ctx->vocab.id_to_token[ids[i]];
        }
        return true;
    };

    if (!segments.empty()) {
        std::vector<double> batch;
        size_t batch_seg_count = 0;

        for (size_t si = 0; si < segments.size(); si++) {
            auto &seg = segments[si];
            size_t seg_samples = seg.t1 - seg.t0;

            if (seg_samples < 400) {
                SENSE_VOICE_LOG_WARN("%s: skipping very short segment [%zu-%zu], %zu samples\n",
                    __func__, seg.t0, seg.t1, seg_samples);
                continue;
            }

            size_t add_samples = (batch.empty() ? 0 : silence_samples) + seg_samples;
            if (!batch.empty() && batch.size() + add_samples > max_chunk_samples) {
                SENSE_VOICE_LOG_INFO("%s: flushing batch of %zu segments, %zu samples (%.1fs)\n",
                    __func__, batch_seg_count, batch.size(),
                    (double)batch.size() / SENSE_VOICE_SAMPLE_RATE);
                if (!transcribe_batch(batch)) return nullptr;
                batch.clear();
                batch_seg_count = 0;
            }

            if (!batch.empty()) {
                batch.insert(batch.end(), silence_samples, 0.0);
            }
            batch.insert(batch.end(),
                pcmf64.begin() + seg.t0,
                pcmf64.begin() + seg.t1);
            batch_seg_count++;
        }

        if (!transcribe_batch(batch)) return nullptr;

    } else {
        // VAD found nothing — transcribe entire audio
        SENSE_VOICE_LOG_WARN("%s: VAD found no speech, falling back to full-audio path\n", __func__);
        if (!transcribe_batch(pcmf64)) return nullptr;
    }

    if (on_progress) on_progress(1.0f, progress_userdata);

    while (!text.empty() && isspace((unsigned char)text.back())) text.pop_back();
    return strdup(text.c_str());
}

} // extern "C"
