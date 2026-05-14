// asr_engine.cpp — Unified ASR engine backed by llama.cpp + mtmd
#include "asr_engine.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#include "mtmd-audio.h"
#include "llama.h"
#include "ggml.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <cmath>

// ── WAV reader ───────────────────────────────────────────────────────

// 200 MB max for WAV PCM data
static const size_t kMaxWavDataBytes = 200 * 1024 * 1024;

struct wav_data {
    std::vector<float> samples;
    int sample_rate = 0;
};

static bool wav_read(const char * path, wav_data & wav) {
    FILE * f = fopen(path, "rb");
    if (!f) return false;

    char riff[5] = {0}, wave[5] = {0};
    fread(riff, 1, 4, f); riff[4] = 0;
    uint32_t file_size; fread(&file_size, 4, 1, f);
    fread(wave, 1, 4, f); wave[4] = 0;

    if (strcmp(riff, "RIFF") != 0 || strcmp(wave, "WAVE") != 0) {
        fclose(f); return false;
    }

    int16_t bits_per_sample = 0;
    uint16_t audio_format = 0;
    bool has_fmt = false;
    while (!feof(f)) {
        char id[5] = {0};
        if (fread(id, 1, 4, f) < 4) break;
        uint32_t size; fread(&size, 4, 1, f);

        if (strcmp(id, "fmt ") == 0) {
            uint16_t ch; uint32_t sr;
            fread(&audio_format, 2, 1, f); fread(&ch, 2, 1, f); fread(&sr, 4, 1, f);
            fseek(f, 6, SEEK_CUR); fread(&bits_per_sample, 2, 1, f);
            if (size > 16) fseek(f, size - 16, SEEK_CUR);
            wav.sample_rate = (int)sr;
            has_fmt = true;
        } else if (strcmp(id, "data") == 0) {
            if (!has_fmt || audio_format != 1 || bits_per_sample != 16) { fclose(f); return false; }
            if (size > kMaxWavDataBytes) size = kMaxWavDataBytes;
            int n = (int)(size / 2);
            if (n <= 0) { fclose(f); return false; }
            wav.samples.resize(n);
            std::vector<int16_t> buf(n);
            fread(buf.data(), 2, n, f);
            for (int i = 0; i < n; i++)
                wav.samples[i] = buf[i] / 32768.0f;
        } else { fseek(f, size, SEEK_CUR); }
    }
    fclose(f);
    return !wav.samples.empty();
}

static std::vector<float> resample_16k(const wav_data & wav) {
    if (wav.sample_rate == 16000) return wav.samples;
    double ratio = 16000.0 / wav.sample_rate;
    int out_len = (int)(wav.samples.size() * ratio);
    std::vector<float> out(out_len);
    for (int i = 0; i < out_len; i++) {
        double src_idx = i / ratio;
        int idx0 = (int)src_idx;
        int idx1 = idx0 + 1;
        if (idx1 >= (int)wav.samples.size()) idx1 = (int)wav.samples.size() - 1;
        out[i] = (float)(wav.samples[idx0] * (1.0 - (src_idx - idx0)) + wav.samples[idx1] * (src_idx - idx0));
    }
    return out;
}

// ── ASR Context ───────────────────────────────────────────────────────

struct asr_context {
    llama_model   * model   = nullptr;
    llama_context * lctx    = nullptr;
    const llama_vocab * vocab = nullptr;
    mtmd_context  * mtmd_ctx = nullptr;
    int n_batch  = 512;
    bool verbose = false;
};

// ── Public API ────────────────────────────────────────────────────────

extern "C" {

int asr_engine_init(void) {
    llama_backend_init();
    return 0;
}

int asr_engine_probe(void) {
    fprintf(stderr, "asr_engine: llama.cpp + mtmd\n");
    fprintf(stderr, "  ggml backends: %zu\n", ggml_backend_dev_count());
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        auto * dev = ggml_backend_dev_get(i);
        fprintf(stderr, "  [%zu] %s (%s)\n", i,
                ggml_backend_dev_name(dev),
                ggml_backend_dev_description(dev));
    }
    return 0;
}

asr_context * asr_context_create(
    const char * model_path,
    const char * mmproj_path,
    int use_gpu)
{
    auto * ctx = new asr_context();
    ctx->verbose = (getenv("ASR_VERBOSE") != nullptr);

    // Load LLM
    auto mparams = llama_model_default_params();
    if (ctx->verbose) fprintf(stderr, "asr: loading model %s\n", model_path);
    ctx->model = llama_model_load_from_file(model_path, mparams);
    if (!ctx->model) {
        fprintf(stderr, "asr: failed to load model %s\n", model_path);
        delete ctx; return nullptr;
    }

    // Create context
    auto cparams = llama_context_default_params();
    cparams.n_ctx   = 4096;
    cparams.n_batch = ctx->n_batch;
    ctx->lctx = llama_init_from_model(ctx->model, cparams);
    if (!ctx->lctx) {
        fprintf(stderr, "asr: failed to create context\n");
        llama_model_free(ctx->model);
        delete ctx; return nullptr;
    }
    ctx->vocab = llama_model_get_vocab(ctx->model);

    // Load audio encoder
    auto mparams2 = mtmd_context_params_default();
    mparams2.use_gpu       = use_gpu != 0;
    mparams2.print_timings = ctx->verbose;
    mparams2.n_threads     = 4;
    ctx->mtmd_ctx = mtmd_init_from_file(mmproj_path, ctx->model, mparams2);
    if (!ctx->mtmd_ctx) {
        fprintf(stderr, "asr: failed to load mmproj %s\n", mmproj_path);
        llama_free(ctx->lctx);
        llama_model_free(ctx->model);
        delete ctx; return nullptr;
    }

    if (ctx->verbose) {
        fprintf(stderr, "asr: supports_audio=%d, sample_rate=%d\n",
                (int)mtmd_support_audio(ctx->mtmd_ctx),
                mtmd_get_audio_sample_rate(ctx->mtmd_ctx));
    }
    return ctx;
}

void asr_context_free(asr_context * ctx) {
    if (!ctx) return;
    if (ctx->mtmd_ctx) mtmd_free(ctx->mtmd_ctx);
    if (ctx->lctx)     llama_free(ctx->lctx);
    if (ctx->model)    llama_model_free(ctx->model);
    delete ctx;
}

// Shared: run mtmd eval + autoregressive decode
static std::string transcribe_impl(
    asr_context * ctx,
    const float * samples, size_t n_samples,
    const char * prompt_text,
    asr_progress_fn on_progress,
    void * progress_userdata)
{
    // Create audio bitmap
    mtmd::bitmap bmp(mtmd_bitmap_init_from_audio(n_samples, samples));
    if (!bmp.ptr) {
        fprintf(stderr, "asr: failed to create audio bitmap\n");
        return "";
    }
    fprintf(stderr, "asr: audio bitmap n_samples=%zu duration=%.1fs\n",
            n_samples, (double)n_samples / 16000.0);

    // Build text input with Qwen3 chat template + audio marker
    std::string user_msg = prompt_text && prompt_text[0] ? prompt_text : "Transcribe the audio.";
    std::string full_prompt =
        std::string("<|im_start|>user\n") +
        "<__media__>\n" + user_msg + "<|im_end|>\n" +
        "<|im_start|>assistant\n";
    mtmd_input_text text_input;
    text_input.text          = full_prompt.c_str();
    text_input.add_special   = true;
    text_input.parse_special = true;

    // Tokenize
    mtmd::input_chunks chunks(mtmd_input_chunks_init());
    mtmd_bitmap * raw_bmp = bmp.ptr.get();
    int res = mtmd_tokenize(ctx->mtmd_ctx, chunks.ptr.get(), &text_input,
                            (const mtmd_bitmap **)&raw_bmp, 1);
    if (res != 0) {
        fprintf(stderr, "asr: tokenize failed, res=%d\n", res);
        return "";
    }

    // Prefill (encoder + prompt decode)
    if (on_progress) on_progress(0.05f, progress_userdata);
    llama_pos n_past = 0;
    res = mtmd_helper_eval_chunks(
        ctx->mtmd_ctx, ctx->lctx,
        chunks.ptr.get(), n_past,
        {0}, ctx->n_batch, true, &n_past);
    if (res != 0) {
        fprintf(stderr, "asr: eval chunks failed, res=%d\n", res);
        return "";
    }
    if (on_progress) on_progress(0.15f, progress_userdata);

    // Autoregressive decode
    std::string output;
    int max_tokens = 1024;
    llama_token token = 0;
    // Estimate: ~2.5 tokens per second of audio
    float est_tokens = n_samples / 16000.0f * 2.5f;
    if (est_tokens < 20) est_tokens = 20;
    if (est_tokens > max_tokens) est_tokens = (float)max_tokens;

    // Track recent tokens for repetition penalty
    std::vector<llama_token> recent;
    recent.reserve(64);

    for (int i = 0; i < max_tokens; i++) {
        // Greedy sample with repetition penalty
        auto * logits = llama_get_logits_ith(ctx->lctx, -1);
        int n_vocab = llama_vocab_n_tokens(ctx->vocab);
        // Penalize tokens seen in recent window
        for (auto t : recent) {
            logits[t] *= 0.85f;
        }
        float max_logit = -1e30f;
        for (int j = 0; j < n_vocab; j++) {
            if (logits[j] > max_logit) { max_logit = logits[j]; token = j; }
        }
        if (llama_vocab_is_eog(ctx->vocab, token)) break;

        // Track recent tokens (sliding window)
        recent.push_back(token);
        if (recent.size() > 64) recent.erase(recent.begin());

        char piece[256];
        int n_chars = llama_token_to_piece(ctx->vocab, token, piece, sizeof(piece), 0, true);
        if (n_chars > 0) output.append(piece, n_chars);

        // Progress: 15%..95% mapped to token progress
        if (on_progress && (i % 4 == 0)) {
            float pct = 0.15f + 0.80f * ((float)i / est_tokens);
            if (pct > 0.95f) pct = 0.95f;
            on_progress(pct, progress_userdata);
        }

        // Feed token back
        auto batch = llama_batch_get_one(&token, 1);
        if (llama_decode(ctx->lctx, batch) != 0) break;
    }
    if (on_progress) on_progress(1.0f, progress_userdata);

    // Extract text from within <asr_text>...</asr_text> tags
    auto pos_start = output.find("<asr_text>");
    if (pos_start != std::string::npos) {
        pos_start += 10; // strlen("<asr_text>")
        auto pos_end = output.find("</asr_text>", pos_start);
        if (pos_end != std::string::npos) {
            return output.substr(pos_start, pos_end - pos_start);
        }
        return output.substr(pos_start);
    }
    return output;
}

char * asr_transcribe_file(
    asr_context * ctx,
    const char * wav_path,
    const char * prompt_text,
    asr_progress_fn on_progress,
    void * progress_userdata)
{
    if (!ctx || !wav_path) return nullptr;

    wav_data wav;
    if (!wav_read(wav_path, wav)) {
        fprintf(stderr, "asr: failed to read WAV: %s\n", wav_path);
        return nullptr;
    }
    auto samples = resample_16k(wav);
    if (ctx->verbose) fprintf(stderr, "asr: audio %zu samples @ 16kHz\n", samples.size());

    auto result = transcribe_impl(ctx, samples.data(), samples.size(), prompt_text,
                                  on_progress, progress_userdata);
    if (result.empty()) return nullptr;
    return strdup(result.c_str());
}

char * asr_transcribe_audio(
    asr_context * ctx,
    const float * samples,
    int n_samples,
    const char * prompt_text,
    asr_progress_fn on_progress,
    void * progress_userdata)
{
    if (!ctx || !samples || n_samples <= 0) return nullptr;
    auto result = transcribe_impl(ctx, samples, (size_t)n_samples, prompt_text,
                                  on_progress, progress_userdata);
    if (result.empty()) return nullptr;
    return strdup(result.c_str());
}

} // extern "C"
