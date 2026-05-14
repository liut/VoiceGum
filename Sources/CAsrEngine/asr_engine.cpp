// asr_engine.cpp — ASR engine (SenseVoice GGUF via ggml)
#include "asr_engine.h"
#include "ggml-backend.h"

#include <cstdio>

extern "C" {

int asr_engine_init(void) {
    // ggml backends auto-register on first use
    return 0;
}

int asr_engine_probe(void) {
    fprintf(stderr, "asr_engine: ggml + SenseVoice\n");
    fprintf(stderr, "  ggml backends: %zu\n", ggml_backend_dev_count());
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        fprintf(stderr, "  [%zu] %s (%s)\n", i,
                ggml_backend_dev_name(dev),
                ggml_backend_dev_description(dev));
    }
    return 0;
}

} // extern "C"
