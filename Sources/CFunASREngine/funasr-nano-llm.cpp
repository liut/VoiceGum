// funasr-nano-llm.cpp — LLM inference via llama.cpp for FunASR-Nano
#include "funasr-nano.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool add_special) {
    std::vector<llama_token> tokens;
    tokens.resize(text.size() + 16);
    int n = llama_tokenize(vocab, text.c_str(), (int)text.size(), tokens.data(), (int)tokens.size(), add_special, true);
    tokens.resize(n > 0 ? n : 0);
    return tokens;
}

static int decode_batch(llama_context * ctx, int n, llama_token * tok, float * embd,
                         int n_embd, int & n_past, bool last_logits) {
    std::vector<llama_pos> pos(n);
    std::vector<int32_t> nsid(n, 1);
    std::vector<llama_seq_id> s0(1, 0);
    std::vector<llama_seq_id *> sid(n);
    std::vector<int8_t> lg(n, 0);
    for (int i = 0; i < n; i++) { pos[i] = n_past + i; sid[i] = s0.data(); }
    if (last_logits) lg[n - 1] = 1;
    llama_batch b = { n, tok, embd, pos.data(), nsid.data(), sid.data(), lg.data() };
    int r = llama_decode(ctx, b);
    n_past += n;
    return r;
}

// ── Load LLM ──
bool nano_llm_load(const char * path, NanoLLMContext & ctx, int n_threads) {
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = -1; // All layers on GPU
    ctx.model = llama_model_load_from_file(path, mparams);
    if (!ctx.model) return false;

    ctx.vocab = llama_model_get_vocab(ctx.model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = 2048;
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;
    ctx.ctx = llama_init_from_model(ctx.model, cparams);
    if (!ctx.ctx) { llama_model_free(ctx.model); return false; }

    // Greedy sampler
    auto sparams = llama_sampler_chain_default_params();
    ctx.smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(ctx.smpl, llama_sampler_init_greedy());

    // Prompt template (Qwen3 chat format)
    ctx.prefix_tokens = tokenize(ctx.vocab, "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\n语音转写：", true);
    ctx.suffix_tokens = tokenize(ctx.vocab, "<|im_end|>\n<|im_start|>assistant\n", true);

    ctx.n_past = 0;
    return true;
}

// ── Transcribe with audio embeddings ──
std::string nano_llm_transcribe(NanoLLMContext & ctx, const std::vector<float> & audio_embd,
                                  int n_aud, int D) {
    if (n_aud < 1 || audio_embd.empty()) return "";

    // Clear KV cache per window
    llama_memory_clear(llama_get_memory(ctx.ctx), true);
    ctx.n_past = 0;

    // (A) Decode prefix tokens
    if (!ctx.prefix_tokens.empty())
        decode_batch(ctx.ctx, (int)ctx.prefix_tokens.size(), ctx.prefix_tokens.data(), nullptr, 0, ctx.n_past, false);

    // (B) Decode audio embeddings
    decode_batch(ctx.ctx, n_aud, nullptr, (float *)audio_embd.data(), D, ctx.n_past, false);

    // (C) Decode suffix tokens (last with logits)
    if (!ctx.suffix_tokens.empty())
        decode_batch(ctx.ctx, (int)ctx.suffix_tokens.size(), ctx.suffix_tokens.data(), nullptr, 0, ctx.n_past, true);

    // (D) Autoregressive generation
    std::string text;
    llama_token tk = llama_sampler_sample(ctx.smpl, ctx.ctx, -1);
    const int max_tokens = 512;
    for (int i = 0; i < max_tokens; i++) {
        if (llama_vocab_is_eog(ctx.vocab, tk)) break;
        char buf[256];
        int k = llama_token_to_piece(ctx.vocab, tk, buf, sizeof(buf), 0, true);
        if (k > 0) text.append(buf, k);

        decode_batch(ctx.ctx, 1, &tk, nullptr, 0, ctx.n_past, true);
        tk = llama_sampler_sample(ctx.smpl, ctx.ctx, -1);
    }

    return text;
}

void nano_llm_free(NanoLLMContext & ctx) {
    if (ctx.smpl) llama_sampler_free(ctx.smpl);
    if (ctx.ctx) llama_free(ctx.ctx);
    if (ctx.model) llama_model_free(ctx.model);
    ctx = {};
}
