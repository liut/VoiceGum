// sense-voice-encoder-official.cc — SAN-M encoder for official FunASR format
// Uses fused QKV (linear_q_k_v) + shift-accumulate FSMN (no conv1d depthwise)
#include "sense-voice-encoder.h"
#include "common.h"
#include <cstdio>

// ── Official format attention: fused QKV + shift-accumulate FSMN ──

static ggml_tensor * sanm_attn_official(ggml_context * ctx0,
    sense_voice_context & pctx,
    ggml_tensor * cur,
    const sense_voice_layer_encoder & layer,
    ggml_cgraph * gf,
    bool flash_attn)
{
    const auto & hparams = pctx.model.hparams;
    int n_state = hparams.n_encoder_hidden_state;  // 512
    int n_head = hparams.n_encoder_attention_heads; // 4
    int dk = n_state / n_head;
    int K = hparams.fsmn_kernel_size;               // 11
    int n_batch = cur->ne[2];
    int n_ctx = cur->ne[1];  // T (time)

    // Fused QKV: x @ W_qkv^T → [3*D, T]
    ggml_tensor * qkv;
    if (layer.e_attn_ln_qkv_w) {
        // Official format: fused QKV
        qkv = ggml_mul_mat(ctx0, layer.e_attn_ln_qkv_w, cur);
        if (layer.e_attn_ln_qkv_b)
            qkv = ggml_add(ctx0, qkv, layer.e_attn_ln_qkv_b);
    } else {
        // Fallback: separate QKV (lovemefan compat)
        auto q = ggml_mul_mat(ctx0, layer.e_attn_ln_q_w, cur);
        if (layer.e_attn_ln_q_b) q = ggml_add(ctx0, q, layer.e_attn_ln_q_b);
        auto k = ggml_mul_mat(ctx0, layer.e_attn_ln_k_w, cur);
        if (layer.e_attn_ln_k_b) k = ggml_add(ctx0, k, layer.e_attn_ln_k_b);
        auto v = ggml_mul_mat(ctx0, layer.e_attn_ln_v_w, cur);
        if (layer.e_attn_ln_v_b) v = ggml_add(ctx0, v, layer.e_attn_ln_v_b);
        qkv = ggml_concat(ctx0, q, ggml_concat(ctx0, k, v, 0), 0);
    }

    // Split QKV via ggml_view_2d
    size_t nb1 = qkv->nb[1];
    ggml_tensor * Q = ggml_cont(ctx0, ggml_view_2d(ctx0, qkv, n_state, n_ctx, nb1, 0));
    ggml_tensor * K = ggml_cont(ctx0, ggml_view_2d(ctx0, qkv, n_state, n_ctx, nb1, (size_t)n_state * sizeof(float)));
    ggml_tensor * V = ggml_cont(ctx0, ggml_view_2d(ctx0, qkv, n_state, n_ctx, nb1, (size_t)2 * n_state * sizeof(float)));

    // ── Shift-accumulate FSMN (official path) ──
    int pad = (K - 1) / 2;
    ggml_tensor * fk = layer.e_attn_fsmn_w;
    ggml_tensor * vp = ggml_pad_ext(ctx0, V, pad, pad, 0, 0, 0, 0);
    ggml_tensor * fsmn = V;

    for (int j = 0; j < K; j++) {
        auto sl = ggml_view_2d(ctx0, vp, n_state, n_ctx, vp->nb[1], (size_t)j * vp->nb[1]);
        auto wj = ggml_view_1d(ctx0, fk, n_state, (size_t)j * fk->nb[1]);
        // Cast weight to f32 if needed
        if (wj->type != GGML_TYPE_F32) wj = ggml_cast(ctx0, wj, GGML_TYPE_F32);
        fsmn = ggml_add(ctx0, fsmn, ggml_mul(ctx0, ggml_cont(ctx0, sl), wj));
    }

    // Multi-head attention
    Q = ggml_permute(ctx0, ggml_reshape_3d(ctx0, Q, dk, n_head, n_ctx), 0, 2, 1, 3);
    K = ggml_permute(ctx0, ggml_reshape_3d(ctx0, K, dk, n_head, n_ctx), 0, 2, 1, 3);
    ggml_tensor * Vh = ggml_cont(ctx0, ggml_permute(ctx0, ggml_reshape_3d(ctx0, V, dk, n_head, n_ctx), 1, 2, 0, 3));

    float KQscale = 1.0f / sqrtf((float)dk);
    ggml_tensor * KQ = ggml_soft_max(ctx0, ggml_scale(ctx0, ggml_mul_mat(ctx0, K, Q), KQscale));
    ggml_tensor * KQV = ggml_cont_2d(ctx0, ggml_permute(ctx0, ggml_mul_mat(ctx0, Vh, KQ), 0, 2, 1, 3), n_state, n_ctx);

    // Output projection + FSMN residual
    ggml_tensor * attn_out = ggml_mul_mat(ctx0, layer.e_attn_ln_out_w, KQV);
    if (layer.e_attn_ln_out_b) attn_out = ggml_add(ctx0, attn_out, layer.e_attn_ln_out_b);

    return ggml_add(ctx0, attn_out, fsmn);
}

// ── Official format encoder layer ──

static ggml_tensor * encoder_layer_sanm_official(
    const sense_voice_hparams & hparams,
    sense_voice_context & pctx,
    ggml_context * ctx0,
    ggml_tensor * cur,
    const sense_voice_layer_encoder & layer,
    ggml_cgraph * gf,
    bool flash_attn,
    bool residual)
{
    auto r = cur;

    // Pre-attention LayerNorm
    cur = ggml_norm(ctx0, cur, hparams.eps);
    cur = ggml_mul(ctx0, cur, layer.e_norm_w1);
    cur = ggml_add(ctx0, cur, layer.e_norm_b1);

    // Attention
    cur = sanm_attn_official(ctx0, pctx, cur, layer, gf, flash_attn);

    // Residual
    cur = residual ? ggml_add(ctx0, r, cur) : cur;
    r = cur;

    // Post-attention LayerNorm
    cur = ggml_norm(ctx0, cur, hparams.eps);
    cur = ggml_mul(ctx0, cur, layer.e_norm_w2);
    cur = ggml_add(ctx0, cur, layer.e_norm_b2);

    // FFN: Linear1 -> ReLU -> Linear2
    cur = ggml_mul_mat(ctx0, layer.e_mlp_w1, cur);
    if (layer.e_mlp_b1) cur = ggml_add(ctx0, cur, layer.e_mlp_b1);
    cur = ggml_relu(ctx0, cur);
    cur = ggml_mul_mat(ctx0, layer.e_mlp_w2, cur);
    if (layer.e_mlp_b2) cur = ggml_add(ctx0, cur, layer.e_mlp_b2);

    // Residual
    return ggml_add(ctx0, r, cur);
}

// ── Official format graph builder ──

struct ggml_cgraph * sense_voice_build_graph_encoder_official(
    sense_voice_context & pctx,
    sense_voice_state & state)
{
    const auto & hparams = pctx.model.hparams;
    const int n_state = hparams.n_encoder_hidden_state;
    const int n_encoder_layer = hparams.n_encoder_layers;
    const int n_tp_encoder_layer = hparams.n_tp_encoder_layers;
    int n_batch = 1;
    int n_ctx = state.feature.n_len;

    auto * model = pctx.model.model;
    struct ggml_init_params params = {
        /*.mem_size   =*/ ggml_tensor_overhead() * SENSE_VOICE_ENCODER_MAX_NODES,
        /*.mem_buffer =*/ nullptr,
        /*.no_alloc   =*/ true,
    };
    struct ggml_context * ctx0 = ggml_init(params);

    struct ggml_cgraph * gf = ggml_new_graph_custom(ctx0, SENSE_VOICE_ENCODER_MAX_NODES, false);

    // Input: feature tensor [n_mels*lfr_m, T]
    struct ggml_tensor * cur = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, state.feature.data.size() / state.feature.n_len, state.feature.n_len);
    ggml_set_name(cur, "feature");
    ggml_set_input(cur);

    // Concat language embedding
    struct ggml_tensor * embedding = ggml_new_tensor_2d(ctx0, GGML_TYPE_I32, 4, 1);
    ggml_set_name(embedding, "embedding");
    ggml_set_input(embedding);
    embedding = ggml_get_rows(ctx0, model->embedding, embedding);
    embedding = ggml_repeat(ctx0, embedding, ggml_new_tensor_3d(ctx0, GGML_TYPE_I32, embedding->ne[0], embedding->ne[1], cur->ne[2]));
    cur = ggml_concat(ctx0, embedding, cur, 1);

    // Scale input and add position encoding
    float sc = sqrtf((float)n_state);
    cur = ggml_scale(ctx0, cur, sc);
    // Position encoding via sinusoidal embedding
    struct ggml_tensor * pos_enc = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, cur->ne[0], cur->ne[1]);
    ggml_set_name(pos_enc, "pos_enc");
    ggml_set_input(pos_enc);
    cur = ggml_add(ctx0, cur, pos_enc);

    // Encoder 0 (no residual)
    cur = encoder_layer_sanm_official(hparams, pctx, ctx0, cur, model->encoder->encoder0, gf, pctx.params.flash_attn, false);

    // Encoder layers 1..N-1 (with residual)
    for (int i = 0; i < n_encoder_layer - 1; i++) {
        cur = encoder_layer_sanm_official(hparams, pctx, ctx0, cur, model->encoder->encoders_layer[i], gf, pctx.params.flash_attn, true);
    }

    // After norm
    cur = ggml_norm(ctx0, cur, hparams.eps);
    cur = ggml_mul(ctx0, cur, model->encoder->e_after_norm_w);
    cur = ggml_add(ctx0, cur, model->encoder->e_after_norm_b);

    // TP encoder layers (with residual)
    for (int i = 0; i < n_tp_encoder_layer; i++) {
        cur = encoder_layer_sanm_official(hparams, pctx, ctx0, cur, model->encoder->tp_encoders_layer[i], gf, pctx.params.flash_attn, true);
    }

    // TP norm
    cur = ggml_norm(ctx0, cur, hparams.eps);
    cur = ggml_mul(ctx0, cur, model->encoder->e_tp_norm_w);
    cur = ggml_add(ctx0, cur, model->encoder->e_tp_norm_b);

    // CTC head
    cur = ggml_mul_mat(ctx0, model->ctc_out_linear_weight, cur);
    if (model->ctc_out_linear_bias)
        cur = ggml_add(ctx0, cur, model->ctc_out_linear_bias);

    ggml_set_name(cur, "ctc_out");
    ggml_set_output(cur);

    ggml_build_forward_expand(gf, cur);
    ggml_free(ctx0);

    return gf;
}

// ── Official format encoder forward ──

bool sense_voice_encode_internal_official(
    sense_voice_context & ctx,
    sense_voice_state & state,
    int n_threads)
{
    const auto & hparams = ctx.model.hparams;
    const int n_state = hparams.n_encoder_hidden_state;
    int n_batch = 1;
    int n_ctx = state.feature.n_len;

    // Build position encoding
    std::vector<float> pos_enc_data;
    {
        int depth = hparams.n_encoder_0_norm_size;  // 560
        int total_tokens = state.feature.n_len + 4;  // T + 4 language tokens
        pos_enc_data.resize((size_t)total_tokens * depth, 0.0f);
        double inc = log(10000.0) / (depth / 2.0 - 1.0);
        for (int t = 0; t < total_tokens; t++) {
            double pos = t + 1;
            for (int i = 0; i < depth / 2; i++) {
                double its = exp(i * -inc), st = pos * its;
                pos_enc_data[(size_t)t * depth + i] = (float)sin(st);
                pos_enc_data[(size_t)t * depth + depth / 2 + i] = (float)cos(st);
            }
        }
    }

    int _embedding[4] = { ctx.language_id, 1, 2, ctx.params.use_itn ? 14 : 15 };

    // Free previous graph
    if (state.sense_voice_encoder_graph) {
        ggml_gallocr_free(state.sched_encode.sched);
        state.sched_encode.sched = nullptr;
        state.sense_voice_encoder_graph = nullptr;
    }

    state.sense_voice_encoder_graph = sense_voice_build_graph_encoder_official(ctx, state);
    if (!state.sense_voice_encoder_graph) {
        SENSE_VOICE_LOG_ERROR("%s: failed to build official encoder graph\n", __func__);
        return false;
    }

    // Allocate compute
    if (!ggml_gallocr_alloc_graph(state.sched_encode.sched, state.sense_voice_encoder_graph)) {
        SENSE_VOICE_LOG_ERROR("%s: failed to alloc official encoder graph\n", __func__);
        return false;
    }

    // Set inputs
    {
        struct ggml_tensor * feature = ggml_graph_get_tensor(state.sense_voice_encoder_graph, "feature");
        ggml_backend_tensor_set(feature, state.feature.data.data(), 0, ggml_nbytes(feature));

        struct ggml_tensor * embedding = ggml_graph_get_tensor(state.sense_voice_encoder_graph, "embedding");
        ggml_backend_tensor_set(embedding, _embedding, 0, 4 * sizeof(int));

        struct ggml_tensor * pos_enc = ggml_graph_get_tensor(state.sense_voice_encoder_graph, "pos_enc");
        if (pos_enc)
            ggml_backend_tensor_set(pos_enc, pos_enc_data.data(), 0, ggml_nbytes(pos_enc));
    }

    // Compute
    if (!ggml_graph_compute_helper(state.sched_encode.sched, state.sense_voice_encoder_graph, n_threads)) {
        SENSE_VOICE_LOG_ERROR("%s: official encoder compute failed\n", __func__);
        return false;
    }

    // Extract output
    state.encoder_out = ggml_graph_get_tensor(state.sense_voice_encoder_graph, "ctc_out");

    return true;
}
