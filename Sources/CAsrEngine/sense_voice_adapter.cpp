// sense_voice_adapter.cpp — Bridge between our C API and SenseVoice.cpp ggml code
#include "sense-voice.h"
#include "common.h"
#include "asr_engine.h"

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

    // VAD + transcribe (from main.cc logic)
    auto & ctx = w->ctx;
    ctx->language_id = sense_voice_lang_id(language);

    sense_voice_full_params wparams = sense_voice_full_default_params(SENSE_VOICE_SAMPLING_GREEDY);
    wparams.n_threads = n_threads;
    wparams.print_progress = false;
    wparams.print_timestamps = false;
    wparams.language = language;

    // Simple non-VAD path: transcribe entire audio
    // (VAD is complex, porting would take significant effort)
    ctx->state->duration = (float)pcmf64.size() / sample_rate;

    progress_bridge bridge = { on_progress, progress_userdata };
    if (on_progress) {
        wparams.progress_callback = bridge_progress_callback;
        wparams.progress_callback_user_data = &bridge;
    }

    int ret = sense_voice_full_parallel(ctx, wparams, pcmf64, (int)pcmf64.size(), 1);
    if (ret != 0) {
        fprintf(stderr, "sv: transcription failed, ret=%d\n", ret);
        return nullptr;
    }

    // Extract text from decoder output
    std::string text;
    auto & ids = ctx->state->ids;
    for (size_t i = 4; i < ids.size(); i++) {
        if (i > 4 && ids[i-1] == ids[i]) continue;
        if (ids[i]) text += ctx->vocab.id_to_token[ids[i]];
    }

    if (on_progress) on_progress(1.0f, progress_userdata);

    // Trim and return
    while (!text.empty() && isspace((unsigned char)text.back())) text.pop_back();
    return strdup(text.c_str());
}

} // extern "C"
