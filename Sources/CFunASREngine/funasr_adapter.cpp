// sense_voice_adapter.cpp — Bridge between our C API and SenseVoice.cpp ggml code
#include "sense-voice.h"
#include "common.h"
#include "silero-vad.h"
#include "funasr_engine.h"

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
    funasr_progress_fn fn;
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
    funasr_progress_fn on_progress,
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

sv_result sv_transcribe_segments(
    void * handle,
    const char * wav_path,
    const char * language,
    int n_threads,
    funasr_progress_fn on_progress,
    void * progress_userdata)
{
    sv_result result = {nullptr, 0, nullptr};

    auto * w = (sense_voice_wrapper *)handle;
    if (!w || !w->loaded) return result;

    std::vector<double> pcmf64;
    int sample_rate = 16000;
    if (!load_wav_samples(wav_path, pcmf64, sample_rate)) {
        fprintf(stderr, "sv: failed to load WAV %s\n", wav_path);
        return result;
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

    result.language = strdup(language);

    // ── VAD pipeline (same as sv_transcribe) ──
    const size_t total_samples = pcmf64.size();

    std::vector<float> pcmf32(total_samples);
    for (size_t i = 0; i < total_samples; i++) {
        pcmf32[i] = (float)(pcmf64[i] / 32768.0);
    }

    silero_vad_reset_state(*ctx->state);
    silero_vad_with_state(*ctx, *ctx->state, pcmf32, n_threads);

    auto segments = std::move(ctx->state->result_all);
    ctx->state->result_all.clear();

    // ── Filter out very short segments ──
    std::vector<sense_voice_segment> valid_segs;
    for (auto &seg : segments) {
        if (seg.t1 > seg.t0 && (seg.t1 - seg.t0) >= 400) {
            valid_segs.push_back(std::move(seg));
        }
    }

    if (valid_segs.empty()) {
        if (on_progress) on_progress(1.0f, progress_userdata);
        return result;
    }

    result.count = (int)valid_segs.size();
    result.segments = (sv_segment *)calloc(result.count, sizeof(sv_segment));
    if (!result.segments) {
        fprintf(stderr, "sv: allocation failed for %d segments\n", result.count);
        result.count = 0;
        return result;
    }

    // Lambda: run ASR on a batch of samples and return decoded text
    auto run_asr = [&](std::vector<double> &batch) -> std::string {
        ctx->state->duration = (float)batch.size() / SENSE_VOICE_SAMPLE_RATE;
        int ret = sense_voice_full_parallel(ctx, wparams, batch, (int)batch.size(), 1);
        if (ret != 0) {
            SENSE_VOICE_LOG_ERROR("%s: batch transcription failed, ret=%d\n", __func__, ret);
            return {};
        }
        std::string txt;
        auto &ids = ctx->state->ids;
        for (size_t j = 4; j < ids.size(); j++) {
            if (j > 4 && ids[j-1] == ids[j]) continue;
            if (ids[j]) txt += ctx->vocab.id_to_token[ids[j]];
        }
        while (!txt.empty() && isspace((unsigned char)txt.back())) txt.pop_back();
        return txt;
    };

    // Lambda: set time fields for a segment
    auto set_times = [&](int idx, const sense_voice_segment &seg) {
        result.segments[idx].t0_ms = (float)(seg.t0 * 1000.0 / SENSE_VOICE_SAMPLE_RATE);
        result.segments[idx].t1_ms = (float)(seg.t1 * 1000.0 / SENSE_VOICE_SAMPLE_RATE);
    };

    // ── Branch on segment count ──
    if (result.count <= 10) {
        // Per-segment path: transcribe each segment individually
        for (int i = 0; i < result.count; i++) {
            auto &seg = valid_segs[i];

            std::vector<double> seg_pcm(pcmf64.begin() + seg.t0, pcmf64.begin() + seg.t1);
            std::string txt = run_asr(seg_pcm);

            set_times(i, seg);
            result.segments[i].text = strdup(txt.c_str());

            if (on_progress) on_progress((float)(i + 1) / result.count, progress_userdata);
        }
    } else {
        // Batch path: group segments into ~30s windows with 200ms silence padding
        const float MAX_CHUNK_SECONDS = 30.0f;
        const size_t max_chunk_samples = (size_t)(SENSE_VOICE_SAMPLE_RATE * MAX_CHUNK_SECONDS);
        const size_t silence_samples = (size_t)(SENSE_VOICE_SAMPLE_RATE * 0.2);

        std::vector<double> batch;
        std::vector<int> batch_indices;

        // UTF-8 alignment helper: a continuation byte has bits 10xxxxxx (0x80-0xBF)
        auto align_utf8 = [](const std::string& s, size_t pos) -> size_t {
            while (pos < s.size() && (s[pos] & 0xC0) == 0x80) pos++;
            return pos;
        };

        for (int i = 0; i < result.count; i++) {
            auto &seg = valid_segs[i];
            size_t seg_samples = seg.t1 - seg.t0;
            size_t add_samples = (batch.empty() ? 0 : silence_samples) + seg_samples;

            if (!batch.empty() && batch.size() + add_samples > max_chunk_samples) {
                // Flush batch
                SENSE_VOICE_LOG_INFO("%s: flushing batch of %zu segments, %zu samples (%.1fs)\n",
                    __func__, batch_indices.size(), batch.size(),
                    (double)batch.size() / SENSE_VOICE_SAMPLE_RATE);

                std::string batch_text = run_asr(batch);
                fprintf(stderr, "sv: raw batch_text (%zu chars): %s\n", batch_text.size(), batch_text.c_str());

                // Distribute text to segments proportionally by duration
                float total_dur = 0.0f;
                for (int idx : batch_indices) {
                    total_dur += (float)(valid_segs[idx].t1 - valid_segs[idx].t0) / SENSE_VOICE_SAMPLE_RATE;
                }

                size_t char_off = 0;
                for (size_t si = 0; si < batch_indices.size(); si++) {
                    int idx = batch_indices[si];
                    set_times(idx, valid_segs[idx]);

                    // Align to valid UTF-8 character boundary
                    char_off = align_utf8(batch_text, char_off);
                    if (batch_text.empty() || char_off >= batch_text.size()) {
                        result.segments[idx].text = strdup("");
                        continue;
                    }

                    float seg_dur = (float)(valid_segs[idx].t1 - valid_segs[idx].t0) / SENSE_VOICE_SAMPLE_RATE;
                    size_t seg_chars;
                    if (si == batch_indices.size() - 1) {
                        seg_chars = batch_text.size() - char_off;
                    } else {
                        seg_chars = (size_t)(batch_text.size() * seg_dur / total_dur);
                        if (seg_chars == 0) seg_chars = 1;
                        // Align end to next UTF-8 boundary so we don't split a character
                        size_t end_pos = align_utf8(batch_text, char_off + seg_chars);
                        seg_chars = end_pos > char_off ? end_pos - char_off : seg_chars;
                        if (char_off + seg_chars > batch_text.size()) seg_chars = batch_text.size() - char_off;
                    }

                    std::string seg_txt = batch_text.substr(char_off, seg_chars);
                    while (!seg_txt.empty() && isspace((unsigned char)seg_txt.back())) seg_txt.pop_back();
                    while (!seg_txt.empty() && isspace((unsigned char)seg_txt.front())) seg_txt.erase(seg_txt.begin());

                    result.segments[idx].text = strdup(seg_txt.c_str());
                    char_off += seg_chars;
                }

                batch.clear();
                batch_indices.clear();
            }

            if (!batch.empty()) {
                batch.insert(batch.end(), silence_samples, 0.0);
            }
            batch.insert(batch.end(), pcmf64.begin() + seg.t0, pcmf64.begin() + seg.t1);
            batch_indices.push_back(i);
        }

        // Flush final batch
        if (!batch.empty()) {
            SENSE_VOICE_LOG_INFO("%s: flushing final batch of %zu segments, %zu samples (%.1fs)\n",
                __func__, batch_indices.size(), batch.size(),
                (double)batch.size() / SENSE_VOICE_SAMPLE_RATE);

            std::string batch_text = run_asr(batch);
            fprintf(stderr, "sv: raw final batch_text (%zu chars): %s\n", batch_text.size(), batch_text.c_str());

            float total_dur = 0.0f;
            for (int idx : batch_indices) {
                total_dur += (float)(valid_segs[idx].t1 - valid_segs[idx].t0) / SENSE_VOICE_SAMPLE_RATE;
            }

            size_t char_off = 0;
            for (size_t si = 0; si < batch_indices.size(); si++) {
                int idx = batch_indices[si];
                set_times(idx, valid_segs[idx]);

                // Align to valid UTF-8 character boundary
                char_off = align_utf8(batch_text, char_off);
                if (batch_text.empty() || char_off >= batch_text.size()) {
                    result.segments[idx].text = strdup("");
                    continue;
                }

                float seg_dur = (float)(valid_segs[idx].t1 - valid_segs[idx].t0) / SENSE_VOICE_SAMPLE_RATE;
                size_t seg_chars;
                if (si == batch_indices.size() - 1) {
                    seg_chars = batch_text.size() - char_off;
                } else {
                    seg_chars = (size_t)(batch_text.size() * seg_dur / total_dur);
                    if (seg_chars == 0) seg_chars = 1;
                    size_t end_pos = align_utf8(batch_text, char_off + seg_chars);
                    seg_chars = end_pos > char_off ? end_pos - char_off : seg_chars;
                    if (char_off + seg_chars > batch_text.size()) seg_chars = batch_text.size() - char_off;
                }

                std::string seg_txt = batch_text.substr(char_off, seg_chars);
                while (!seg_txt.empty() && isspace((unsigned char)seg_txt.back())) seg_txt.pop_back();
                while (!seg_txt.empty() && isspace((unsigned char)seg_txt.front())) seg_txt.erase(seg_txt.begin());

                result.segments[idx].text = strdup(seg_txt.c_str());
                char_off += seg_chars;
            }
        }

        if (on_progress) on_progress(1.0f, progress_userdata);
    }

    return result;
}

void sv_free_result(sv_result result) {
    if (result.segments) {
        for (int i = 0; i < result.count; i++) {
            free(result.segments[i].text);
        }
        free(result.segments);
    }
    free(result.language);
}

} // extern "C"

extern "C" int funasr_engine_init(void) { return 0; }
