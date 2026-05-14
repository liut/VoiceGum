// asr_engine.h — ASR C API (SenseVoice GGUF, in-process via ggml)
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Initialize global backend (call once at process start)
int asr_engine_init(void);

// Probe: enumerate backends (returns device count)
int asr_engine_probe(void);

// Progress callback: pct 0.0..1.0, userdata passed through
typedef void (*asr_progress_fn)(float pct, void * userdata);

// ── SenseVoice ──

// Load a SenseVoice GGUF model. Returns opaque handle, NULL on failure.
void * sv_load_model(const char * gguf_path, int use_gpu);

// Free the model
void sv_free(void * handle);

// Transcribe WAV file (blocking). Returns malloced string.
char * sv_transcribe(
    void * handle,
    const char * wav_path,
    const char * language,
    int n_threads,
    asr_progress_fn on_progress,
    void * progress_userdata);

#ifdef __cplusplus
}
#endif
