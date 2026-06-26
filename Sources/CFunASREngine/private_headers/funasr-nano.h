// funasr-nano.h — FunASR-Nano internal types and API
#pragma once
#include "ggml.h"
#include "ggml-cpu.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "gguf.h"
#include "llama.h"
#include <map>
#include <string>
#include <vector>
#include <utility>

// ── Nano encoder config ──
struct NanoEncoderConfig {
    int d_model = 512, n_head = 4, num_blocks = 50, tp_blocks = 20, kernel = 11;
    int adp_llm = 1024, adp_layers = 2, adp_head = 8;
};

// ── Nano encoder model (encoder GGUF) ──
struct NanoEncoderModel {
    NanoEncoderConfig c;
    ggml_context * ctx_w = nullptr;
    ggml_backend_buffer_t buf = nullptr;
    std::map<std::string, ggml_tensor *> t;
    ggml_tensor * g(const std::string & n) {
        auto it = t.find(n);
        return it == t.end() ? nullptr : it->second;
    }
};

// ── Nano LLM context ──
struct NanoLLMContext {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    const llama_vocab * vocab = nullptr;
    llama_sampler * smpl = nullptr;
    std::vector<llama_token> prefix_tokens;
    std::vector<llama_token> suffix_tokens;
    int n_past = 0;
};

// ── VAD segment ──
struct NanoVADSegment {
    int start_sample;
    int end_sample;
};

// ── API ──
bool nano_encoder_load(const char * path, NanoEncoderModel & m);
std::vector<float> nano_encoder_run(NanoEncoderModel & m, const std::vector<float> & fbank, int T, int F, int & D_out, int & n_aud);

bool nano_llm_load(const char * path, NanoLLMContext & ctx, int n_threads);
std::string nano_llm_transcribe(NanoLLMContext & ctx, const std::vector<float> & audio_embd, int n_aud, int D);
void nano_llm_free(NanoLLMContext & ctx);

std::vector<NanoVADSegment> nano_vad_detect(const std::vector<float> & pcm, int sample_rate);
