// format_detect.cpp — GGUF metadata inspection for SenseVoice format detection
#include "common.h"
#include "ggml.h"
#include "gguf.h"
#include <cstring>

SenseVoiceEncoderFormat detect_sensevoice_format(const char * gguf_path) {
    struct gguf_init_params params;
    memset(&params, 0, sizeof(params));
    params.no_alloc = true;
    struct ggml_context * ctx = nullptr;
    params.ctx = &ctx;

    struct gguf_context * gg = gguf_init_from_file(gguf_path, params);
    if (!gg) return FORMAT_UNKNOWN;

    // Check metadata key prefix to determine format family
    int n_keys = gguf_get_n_kv(gg);
    bool has_funasr_prefix = false, has_encoder_prefix = false;
    for (int i = 0; i < n_keys; i++) {
        const char * key = gguf_get_key(gg, i);
        if (!key) continue;
        if (strncmp(key, "funasr.", 7) == 0) has_funasr_prefix = true;
        if (strncmp(key, "encoder.", 8) == 0) has_encoder_prefix = true;
    }

    // Check tensor names for QKV format
    bool has_fused_qkv = false, has_split_qkv = false;
    int n = gguf_get_n_tensors(gg);
    for (int i = 0; i < n; i++) {
        const char * name = gguf_get_tensor_name(gg, i);
        if (!name) continue;
        if (strstr(name, "linear_q_k_v.weight")) has_fused_qkv = true;
        if (strstr(name, "linear_q.weight")) has_split_qkv = true;
    }

    SenseVoiceEncoderFormat fmt = FORMAT_UNKNOWN;
    if (has_funasr_prefix) {
        // FunASR official: check if it has adaptor (Nano) or just encoder (SenseVoice)
        fmt = (gguf_find_key(gg, "funasr.adp.llm_dim") >= 0) ? FORMAT_NANO : FORMAT_OFFICIAL;
    } else if (has_encoder_prefix || has_split_qkv) {
        fmt = FORMAT_LOVEMEFAN;
    } else if (has_fused_qkv) {
        fmt = FORMAT_OFFICIAL;
    }

    gguf_free(gg);
    return fmt;
}
