// asr_engine.h — Unified ASR C API backed by llama.cpp + mtmd
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Opaque context
typedef struct asr_context asr_context;

// Initialize global backend (call once at process start)
int asr_engine_init(void);

// Probe: enumerate backends (returns device count)
int asr_engine_probe(void);

// Create ASR context with LLM + audio encoder models
// model_path:  GGUF LLM decoder (e.g., qwen3-asr-0.6b-Q8_0.gguf)
// mmproj_path: GGUF audio encoder (e.g., qwen3-asr-0.6b-mmproj-Q8_0.gguf)
// use_gpu:     enable Metal GPU for audio encoder
// Returns NULL on failure
asr_context * asr_context_create(
    const char * model_path,
    const char * mmproj_path,
    int use_gpu);

// Free context
void asr_context_free(asr_context * ctx);

// Progress callback: pct 0.0..1.0, userdata passed through
typedef void (*asr_progress_fn)(float pct, void * userdata);

// Transcribe WAV file (blocking)
// Returns malloced UTF-8 string, caller must free()
char * asr_transcribe_file(
    asr_context * ctx,
    const char * wav_path,
    const char * prompt_text,
    asr_progress_fn on_progress,
    void * progress_userdata);

// Transcribe from float32 mono 16kHz audio samples (blocking)
// Returns malloced UTF-8 string, caller must free()
char * asr_transcribe_audio(
    asr_context * ctx,
    const float * samples,
    int n_samples,
    const char * prompt_text,
    asr_progress_fn on_progress,
    void * progress_userdata);

// ── SenseVoice adapter (GGUF, in-process) ──

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
