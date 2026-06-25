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

// ── Per-segment transcription ──

typedef struct {
    char * text;      // transcribed text for this segment (malloc'd)
    float  t0_ms;     // segment start time in milliseconds
    float  t1_ms;     // segment end time in milliseconds
} sv_segment;

typedef struct {
    sv_segment * segments;  // array of segments
    int          count;     // number of segments
    char       * language;  // language used for transcription
} sv_result;

// Transcribe WAV file with per-segment timing (blocking).
// Returns struct with malloc'd segments and language; free with sv_free_result().
// When segment count ≤ 10: each segment is transcribed individually.
// When segment count > 10: segments are batched into ~30s windows and text is
// distributed proportionally by segment duration.
sv_result sv_transcribe_segments(
    void * handle,
    const char * wav_path,
    const char * language,
    int n_threads,
    asr_progress_fn on_progress,
    void * progress_userdata);

// Free all memory allocated by sv_transcribe_segments()
void sv_free_result(sv_result result);

#ifdef __cplusplus
}
#endif
