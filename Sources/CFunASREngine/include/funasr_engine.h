// funasr_engine.h — FunASR C API (SenseVoice GGUF, in-process via ggml)
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Initialize global backend (call once at process start)
int funasr_engine_init(void);

// Progress callback: pct 0.0..1.0, userdata passed through
typedef void (*funasr_progress_fn)(float pct, void * userdata);

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
    funasr_progress_fn on_progress,
    void * progress_userdata);

// ── Per-segment transcription ──

typedef struct {
    char * text;
    float  t0_ms;
    float  t1_ms;
} sv_segment;

typedef struct {
    sv_segment * segments;
    int          count;
    char       * language;
} sv_result;

// Transcribe WAV file with per-segment timing (blocking).
sv_result sv_transcribe_segments(
    void * handle,
    const char * wav_path,
    const char * language,
    int n_threads,
    funasr_progress_fn on_progress,
    void * progress_userdata);

// Free all memory allocated by sv_transcribe_segments()
void sv_free_result(sv_result result);

// ── FunASR-Nano (encoder + LLM) ──

// Load FunASR-Nano: encoder GGUF + LLM GGUF
void * nano_load_model(const char * enc_gguf, const char * llm_gguf, int n_threads);

// Free Nano handle
void nano_free(void * handle);

// Transcribe WAV file (blocking). Returns malloced string.
char * nano_transcribe(void * handle, const char * wav_path, int n_threads);

#ifdef __cplusplus
}
#endif
