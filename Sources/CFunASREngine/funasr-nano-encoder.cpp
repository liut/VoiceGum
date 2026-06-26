// funasr-nano-encoder.cpp — SAN-M encoder + adaptor for FunASR-Nano
#include "funasr-nano.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

static const float LN_EPS = 1e-5f;

static ggml_tensor * lin_(ggml_context * c, ggml_tensor * w, ggml_tensor * b, ggml_tensor * x) {
    auto y = ggml_mul_mat(c, w, x);
    return b ? ggml_add(c, y, ggml_cast(c, b, GGML_TYPE_F32)) : y;
}
static ggml_tensor * lnorm_(ggml_context * c, ggml_tensor * x, ggml_tensor * g, ggml_tensor * b) {
    return ggml_add(c, ggml_mul(c, ggml_norm(c, x, LN_EPS), ggml_cast(c, g, GGML_TYPE_F32)), ggml_cast(c, b, GGML_TYPE_F32));
}

// Shift-accumulate FSMN attention (official format)
static ggml_tensor * sanm_attn_nano(ggml_context * c, NanoEncoderModel & m,
                                     const std::string & p, ggml_tensor * x, int T) {
    const int D = m.c.d_model, H = m.c.n_head, dk = D / H, K = m.c.kernel;
    auto w = m.g(p + "linear_q_k_v.weight");
    auto b = m.g(p + "linear_q_k_v.bias");

    ggml_tensor * qkv;
    if (w) {
        qkv = ggml_mul_mat(c, w, x);
        if (b) qkv = ggml_add(c, qkv, ggml_cast(c, b, GGML_TYPE_F32));
        qkv = ggml_cont(c, qkv);
    } else {
        // Fallback: separate QKV
        auto q = ggml_mul_mat(c, m.g(p + "linear_q.weight"), x);
        auto k = ggml_mul_mat(c, m.g(p + "linear_k.weight"), x);
        auto v = ggml_mul_mat(c, m.g(p + "linear_v.weight"), x);
        qkv = ggml_concat(c, q, ggml_concat(c, k, v, 0), 0);
    }

    size_t nb1 = qkv->nb[1];
    size_t elem_size = ggml_type_size(qkv->type);
    size_t row_bytes = (size_t)D * elem_size;
    ggml_tensor * Q = ggml_cont(c, ggml_view_2d(c, qkv, D, T, nb1, 0));
    ggml_tensor * Kt = ggml_cont(c, ggml_view_2d(c, qkv, D, T, nb1, row_bytes));
    ggml_tensor * V = ggml_cont(c, ggml_view_2d(c, qkv, D, T, nb1, 2 * row_bytes));

    // Shift-accumulate FSMN (GPU-safe: concat zeros instead of pad_ext)
    int pad = (K - 1) / 2;
    ggml_tensor * fk = m.g(p + "fsmn_block.weight");
    // Create zero padding: X - X = 0 for D*pad elements
    auto v_slice = ggml_view_1d(c, V, (size_t)D * pad, 0);
    auto zpad = ggml_reshape_2d(c, ggml_sub(c, v_slice, v_slice), D, pad);
    auto vp = ggml_concat(c, ggml_concat(c, zpad, V, 1), zpad, 1);
    ggml_tensor * fsmn = V;
    for (int j = 0; j < K; j++) {
        auto sl = ggml_view_2d(c, vp, D, T, vp->nb[1], (size_t)j * vp->nb[1]);
        auto wj = ggml_view_1d(c, fk, D, (size_t)j * fk->nb[1]);
        if (wj->type != GGML_TYPE_F32) wj = ggml_cast(c, wj, GGML_TYPE_F32);
        fsmn = ggml_add(c, fsmn, ggml_mul(c, ggml_cont(c, sl), wj));
    }

    Q = ggml_permute(c, ggml_reshape_3d(c, Q, dk, H, T), 0, 2, 1, 3);
    Kt = ggml_permute(c, ggml_reshape_3d(c, Kt, dk, H, T), 0, 2, 1, 3);
    ggml_tensor * Vh = ggml_cont(c, ggml_permute(c, ggml_reshape_3d(c, V, dk, H, T), 1, 2, 0, 3));
    auto KQ = ggml_soft_max(c, ggml_scale(c, ggml_mul_mat(c, Kt, Q), 1.0f / sqrtf((float)dk)));
    auto O = ggml_cont_2d(c, ggml_permute(c, ggml_mul_mat(c, Vh, KQ), 0, 2, 1, 3), D, T);
    return ggml_add(c, lin_(c, m.g(p + "linear_out.weight"), m.g(p + "linear_out.bias"), O), fsmn);
}

static ggml_tensor * sanm_layer_nano(ggml_context * c, NanoEncoderModel & m,
                                      const std::string & p, ggml_tensor * x, int T, bool res) {
    auto r = x;
    auto h = lnorm_(c, x, m.g(p + "norm1.weight"), m.g(p + "norm1.bias"));
    auto sa = sanm_attn_nano(c, m, p + "self_attn.", h, T);
    x = res ? ggml_add(c, r, sa) : sa; r = x;
    h = lnorm_(c, x, m.g(p + "norm2.weight"), m.g(p + "norm2.bias"));
    h = lin_(c, m.g(p + "feed_forward.w_1.weight"), m.g(p + "feed_forward.w_1.bias"), h);
    h = ggml_relu(c, h);
    h = lin_(c, m.g(p + "feed_forward.w_2.weight"), m.g(p + "feed_forward.w_2.bias"), h);
    return ggml_add(c, r, h);
}

// Adaptor MHA layer
static ggml_tensor * adp_layer_nano(ggml_context * c, NanoEncoderModel & m,
                                     const std::string & p, ggml_tensor * x, int T) {
    const int D = m.c.adp_llm, H = m.c.adp_head, dk = D / H;
    auto r = x;
    auto h = lnorm_(c, x, m.g(p + "norm1.weight"), m.g(p + "norm1.bias"));
    auto q = ggml_permute(c, ggml_reshape_3d(c, lin_(c, m.g(p + "self_attn.linear_q.weight"), m.g(p + "self_attn.linear_q.bias"), h), dk, H, T), 0, 2, 1, 3);
    auto k = ggml_permute(c, ggml_reshape_3d(c, lin_(c, m.g(p + "self_attn.linear_k.weight"), m.g(p + "self_attn.linear_k.bias"), h), dk, H, T), 0, 2, 1, 3);
    auto vh = ggml_cont(c, ggml_permute(c, ggml_reshape_3d(c, lin_(c, m.g(p + "self_attn.linear_v.weight"), m.g(p + "self_attn.linear_v.bias"), h), dk, H, T), 1, 2, 0, 3));
    auto kq = ggml_soft_max(c, ggml_scale(c, ggml_mul_mat(c, k, q), 1.0f / sqrtf((float)dk)));
    auto o = ggml_cont_2d(c, ggml_permute(c, ggml_mul_mat(c, vh, kq), 0, 2, 1, 3), D, T);
    x = ggml_add(c, r, lin_(c, m.g(p + "self_attn.linear_out.weight"), m.g(p + "self_attn.linear_out.bias"), o)); r = x;
    h = lnorm_(c, x, m.g(p + "norm2.weight"), m.g(p + "norm2.bias"));
    h = lin_(c, m.g(p + "feed_forward.w_1.weight"), m.g(p + "feed_forward.w_1.bias"), h);
    h = ggml_relu(c, h);
    h = lin_(c, m.g(p + "feed_forward.w_2.weight"), m.g(p + "feed_forward.w_2.bias"), h);
    return ggml_add(c, r, h);
}

static void add_posenc_nano(std::vector<float> & x, int T, int depth) {
    double inc = log(10000.0) / (depth / 2.0 - 1.0);
    for (int t = 0; t < T; t++) {
        double pos = t + 1;
        for (int i = 0; i < depth / 2; i++) {
            double its = exp(i * -inc), st = pos * its;
            x[(size_t)t * depth + i] += (float)sin(st);
            x[(size_t)t * depth + depth / 2 + i] += (float)cos(st);
        }
    }
}

// ── Load encoder GGUF ──
bool nano_encoder_load(const char * path, NanoEncoderModel & m) {
    // Load GGUF with no_alloc — tensors are shapes only, data stays in file
    gguf_init_params gp = { true, &m.ctx_w };
    gguf_context * g = gguf_init_from_file(path, gp);
    if (!g) return false;

    auto rd = [&](const char * k, int d) {
        int i = gguf_find_key(g, k);
        return i < 0 ? d : (int)gguf_get_val_u32(g, i);
    };
    m.c.d_model = rd("funasr.enc.output_size", 512);
    m.c.n_head = rd("funasr.enc.attention_heads", 4);
    m.c.num_blocks = rd("funasr.enc.num_blocks", 50);
    m.c.tp_blocks = rd("funasr.enc.tp_blocks", 20);
    m.c.kernel = rd("funasr.enc.kernel_size", 11);
    m.c.adp_llm = rd("funasr.adp.llm_dim", 1024);
    m.c.adp_layers = rd("funasr.adp.n_layer", 2);
    m.c.adp_head = rd("funasr.adp.attention_heads", 8);

    // Map tensor names
    int n_tensors = gguf_get_n_tensors(g);
    for (int i = 0; i < n_tensors; i++)
        m.t[gguf_get_tensor_name(g, i)] = ggml_get_tensor(m.ctx_w, gguf_get_tensor_name(g, i));

    // Allocate tensors to GPU buffer
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU) {
            auto buft = ggml_backend_dev_buffer_type(dev);
            m.buf = ggml_backend_alloc_ctx_tensors_from_buft(m.ctx_w, buft);
            if (m.buf) ggml_backend_buffer_set_usage(m.buf, GGML_BACKEND_BUFFER_USAGE_WEIGHTS);
            break;
        }
    }
    if (!m.buf) {
        // Fallback: allocate on CPU
        m.buf = ggml_backend_alloc_ctx_tensors_from_buft(m.ctx_w, ggml_backend_cpu_buffer_type());
    }

    // Load tensor data from file
    {
        std::ifstream fin(path, std::ios::binary);
        if (!fin) { gguf_free(g); return false; }

        std::vector<uint8_t> read_buf;
        for (int i = 0; i < n_tensors; i++) {
            const char * name = gguf_get_tensor_name(g, i);
            auto * cur = m.t[name];
            if (!cur) continue;

            size_t offset = gguf_get_data_offset(g) + gguf_get_tensor_offset(g, i);
            fin.seekg(offset, std::ios::beg);
            if (!fin) { gguf_free(g); return false; }

            int nbytes = ggml_nbytes(cur);
            if (ggml_backend_buffer_is_host(m.buf)) {
                fin.read(reinterpret_cast<char *>(cur->data), nbytes);
            } else {
                read_buf.resize(nbytes);
                fin.read(reinterpret_cast<char *>(read_buf.data()), nbytes);
                ggml_backend_tensor_set(cur, read_buf.data(), 0, nbytes);
            }
        }
    }

    gguf_free(g);
    return true;
}

// ── Run encoder + adaptor: fbank [T, F] → audio embeddings [n_aud, D_out] ──
std::vector<float> nano_encoder_run(NanoEncoderModel & m, const std::vector<float> & fbank,
                                     int T, int /*F*/, int & D_out, int & n_aud) {
    const int D = m.c.d_model;
    float sc = sqrtf((float)D);

    // Scale and add position encoding
    std::vector<float> inp = fbank;
    for (auto & v : inp) v *= sc;
    add_posenc_nano(inp, T, (int)inp.size() / T);

    ggml_backend_t be = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_GPU, nullptr);
    if (!be) be = ggml_backend_cpu_init();
    ggml_init_params cp = { (size_t)1024 * 1024 * 1024, nullptr, true };
    ggml_context * c = ggml_init(cp);

    int F_actual = (int)inp.size() / T;
    ggml_tensor * input_t = ggml_new_tensor_2d(c, GGML_TYPE_F32, F_actual, T);
    ggml_set_input(input_t);

    // SAN-M encoder
    ggml_tensor * x = sanm_layer_nano(c, m, "audio_encoder.encoders0.0.", input_t, T, false);
    for (int i = 0; i < m.c.num_blocks - 1; i++)
        x = sanm_layer_nano(c, m, "audio_encoder.encoders." + std::to_string(i) + ".", x, T, true);
    x = lnorm_(c, x, m.g("audio_encoder.after_norm.weight"), m.g("audio_encoder.after_norm.bias"));
    for (int i = 0; i < m.c.tp_blocks; i++)
        x = sanm_layer_nano(c, m, "audio_encoder.tp_encoders." + std::to_string(i) + ".", x, T, true);
    x = lnorm_(c, x, m.g("audio_encoder.tp_norm.weight"), m.g("audio_encoder.tp_norm.bias"));

    // Adaptor: linear projection 512→1024
    x = lin_(c, m.g("audio_adaptor.linear1.weight"), m.g("audio_adaptor.linear1.bias"), x);
    x = ggml_relu(c, x);
    x = lin_(c, m.g("audio_adaptor.linear2.weight"), m.g("audio_adaptor.linear2.bias"), x);

    // Adaptor Transformer layers
    for (int i = 0; i < m.c.adp_layers; i++)
        x = adp_layer_nano(c, m, "audio_adaptor.blocks." + std::to_string(i) + ".", x, T);

    ggml_set_output(x);
    ggml_cgraph * gf = ggml_new_graph_custom(c, 8192, false);
    ggml_build_forward_expand(gf, x);
    ggml_gallocr_t ga = ggml_gallocr_new(ggml_backend_get_default_buffer_type(be));
    ggml_gallocr_alloc_graph(ga, gf);

    ggml_backend_tensor_set(input_t, inp.data(), 0, ggml_nbytes(input_t));
    ggml_backend_graph_compute(be, gf);

    D_out = (int)x->ne[0];
    std::vector<float> out((size_t)D_out * T);
    ggml_backend_tensor_get(x, out.data(), 0, ggml_nbytes(x));

    // Low-frame-rate truncation (critical — matches original SenseVoice frontend stride)
    int ol = 1 + (T - 3 + 2) / 2;
    ol = 1 + (ol - 3 + 2) / 2;
    n_aud = (ol - 1) / 2 + 1;
    if (n_aud > T) n_aud = T;

    // Keep only first n_aud frames
    std::vector<float> aud((size_t)n_aud * D_out);
    memcpy(aud.data(), out.data(), (size_t)n_aud * D_out * sizeof(float));

    ggml_gallocr_free(ga);
    ggml_free(c);
    ggml_backend_free(be);
    return aud;
}
