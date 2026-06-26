---
title: feat: Replace CAsrEngine with FunASR official runtime (Phase 1 — SenseVoice)
type: feat
status: active
date: 2026-06-25
origin: docs/brainstorms/2026-06-25-funasr-nano-engine-requirements.md
---

# feat: Replace CAsrEngine with FunASR official runtime (Phase 1 — SenseVoice)

## Summary

用 FunASR 官方 C++ GGUF runtime（modelscope/FunASR `runtime/llama.cpp/`）编译为静态库，新建 SPM target `CFunASREngine` 包含 C 桥接层，替换当前 `CAsrEngine` 目标。Phase 1 完成 SenseVoice 双格式兼容（lovemefan 分离式 QKV + CMVN 和官方融合式 QKV + raw fbank），复用现有 AudioConverter、TranscriptionService 协议、ModelDownloadManager 基础设施。CPU-only 验证，不含 Metal 加速和 FunASR-Nano 集成。

---

## Problem Frame

VoiceGum 当前 CAsrEngine 仅支持 lovemefan 格式的 SenseVoice Small GGUF 模型，不支持 FunASR 官方 GGUF 格式，也无法加载 FunASR-Nano 等多语言模型。需要替换为官方统一 runtime 以获得双格式 SenseVoice 能力，为 Phase 2 FunASR-Nano 集成铺垫。

(see origin: docs/brainstorms/2026-06-25-funasr-nano-engine-requirements.md)

---

## Requirements

**模型支持**
- R1. 引擎加载 SenseVoiceSmall GGUF 时自动检测并适配 lovemefan（分离式 QKV + CMVN）和官方（融合式 QKV + raw fbank）两种格式
- R2. （Phase 2）引擎支持加载 FunASR-Nano 的 encoder + LLM 两个 GGUF 文件

**转录能力**
- R3. 支持从音频文件离线整段转录
- R4. 转录结果包含文本，分段信息由 VAD 提供

**集成约束**
- R5. 模型切换时正确释放旧模型资源
- R6. 从 FunASR 官方 CLI 源码提取核心推理函数，封装为 C 桥接层
- R7. 引擎支持进度回调

**Origin actors:** A1 (最终用户), A2 (ASR 引擎), A3 (VoiceGum App)
**Origin flows:** F1 (模型发现与加载), F2 (多语言音频转录), F3 (模型切换)
**Origin acceptance examples:** AE1 (lovemefan 格式转录一致性), AE2 (官方格式转录正确性), AE3 (模型切换无泄漏)

---

## Scope Boundaries

- 不包含 Metal GPU 加速（Phase 1 CPU-only）
- 不包含 FunASR-Nano 模型加载（Phase 2）
- 不包含流式/实时识别、hotword、情感检测
- 不包含模型的自动下载 UI 集成（手动放置 GGUF 验证）
- 不修改 SwiftUI 界面
- 不包含 Paraformer 模型支持

### Deferred to Follow-Up Work

- Metal GPU 加速：Phase 2 或独立任务，需要在 llama.cpp Metal backend 与 FunASR runtime ggml 版本间验证兼容性
- FunASR-Nano 集成：Phase 2，需加载 encoder + LLM 双 GGUF 文件，验证 31 语言推理
- 旧 lovemefan 格式废弃计划：在双格式稳定运行后逐步引导用户迁移
- FunASR-Nano 推理速度基准测试：Apple Silicon CPU 实测 RTF

---

## Context & Research

### Relevant Code and Patterns

- `Sources/CAsrEngine/include/asr_engine.h` — C API 模式: `sv_load_model` / `sv_transcribe` / `sv_transcribe_segments` / `sv_free`
- `Sources/CAsrEngine/sense_voice_adapter.cpp` — C API 实现: VAD 分段、批处理拼接、进度回调桥接
- `Sources/Services/Transcription/GGMLTranscriptionService.swift` — Swift 侧集成: `loadModel()` 扫描 .gguf、`transcribe()` 调 C API、Unmanaged 回调桥接
- `Sources/Services/Audio/AudioConverter.swift` — 音频预处理: AVAssetReader → 16kHz 16-bit mono WAV，可直接复用
- `Sources/Services/Transcription/ModelDownloadManager.swift` — actor 模式下载管理，ModelInfo.hfFiles 数组已支持多文件
- `Sources/Core/TranscriptionViewModel.swift` — `setupTranscriptionService()` 引擎分发
- `Package.swift` — CAsrEngine target 的 unsafeFlags / linkerSettings 模式
- `/tmp/FunASR/runtime/llama.cpp/` — 官方 runtime 源码，已验证 CMake 构建成功
- `docs/plans/2026-05-14-003-feat-unified-ggml-asr-engine-plan.md` — 被本计划替代的早期统一方案（用上游 llama.cpp）
- AGENTS.md — ggml Metal 独占约束、`_exit(0)` 绕过析构崩溃、`CAsrEngine` 需 `unsafeFlags`

### Institutional Learnings

- 无 `docs/solutions/` 目录
- `todos/010-pending-p1-llama-backend-lifecycle.md` — ggml backend init/free 必须进程级单次调用
- `todos/013-pending-p2-thread-safety-ggml-service.md` — GGMLTranscriptionService 线程安全问题（NSLock + isTranscribing），新引擎应从一开始使用更严格的并发模型
- ASR 性能基准 (2026-05-14): SenseVoice Metal RTF 0.01, CPU 预期 RTF < 0.1

### External References

- FunASR runtime DESIGN.md (`/tmp/FunASR/runtime/llama.cpp/DESIGN.md`) — fbank pipeline、SAN-M encoder in ggml、FSMN shift-accumulate、SenseVoice raw fbank 无 CMVN
- FunASR runtime CMakeLists.txt — `FETCHCONTENT_SOURCE_DIR_LLAMA` 支持本地 llama.cpp checkout

---

## Key Technical Decisions

- **新建 CFunASREngine 目标而非原地修改 CAsrEngine**: 保留 CAsrEngine 作为 fallback，验证通过后切换 `VoiceGumServices` 依赖。两个 target 不同时链接，避免 ggml 符号冲突
- **CMake 外部构建 + Makefile 集成**: FunASR runtime 使用 CMake 并依赖 llama.cpp，SPM 无法直接表达。通过 `make funasr-libs` 步骤编译静态库（`libfunasr-sensevoice.a` + 重建的 `libggml*.a`），SPM target 链接。与当前 `Sources/CAsrEngine/libs/` 模式一致
- **C API 兼容优先**: 新 C 桥接层导出与 `asr_engine.h` 相同签名的函数（`sv_load_model` / `sv_transcribe_segments` / `sv_free` / `sv_free_result`），确保 `GGMLTranscriptionService` 改动最小
- **格式检测通过 GGUF tensor 名**: 两种格式的 metadata key 均使用 `sv.*` 前缀，不可用于区分。检测 QKV tensor 名——官方格式含 `linear_q_k_v.weight`（融合式），lovemefan 含 `linear_q.weight`（分离式）。CMVN 模式与 QKV 模式绑定（融合→raw fbank，分离→CMVN）
- **CPU-only 后端**: Phase 1 使用 `ggml_backend_cpu_init()`。Metal 在 Phase 2 恢复——通过 llama.cpp 的 Metal backend，需要验证与当前 ggml 版本的兼容性
- **SenseVoice 双格式共享同一 encoder**: QKV 模式分支在加载时完成（分离式 concatenate → fused shape），推理路径统一

---

## Open Questions

### Resolved During Planning

- FunASR runtime 是否提供可复用的 C 库 API: 已验证为 CLI 形态，需要提取核心函数封装为库
- lovemefan GGUF 与官方 GGUF 是否兼容: 已验证差异为 QKV 投影方式 + CMVN 处理，可分支解决
- 本地 llama.cpp 是否可用于构建: 已验证 `FETCHCONTENT_SOURCE_DIR_LLAMA` 支持

### Deferred to Implementation

- FunASR-Nano 在 Apple Silicon 上的实际推理速度: 需要实测，44s 音频参考 ~7s CPU
- 官方 GGUF 的 ModelScope 镜像可用性: 需在下载集成时验证
- FSMN-VAD 与当前 Silero VAD 的分段精度对比: 需实测后决定是否迁移 VAD 方案
- Metal backend 与 FunASR runtime 的 ggml 版本精确兼容性: 需在 Metal 恢复任务中验证

---

## Output Structure

```
Sources/CFunASREngine/
├── include/
│   └── funasr_engine.h          # C API header (mirrors asr_engine.h)
├── funasr_adapter.cpp            # C API implementation + format detection
├── fbank.cpp                     # kaldi fbank + LFR (extracted from CLI)
├── sensevoice_encoder.cpp        # SAN-M encoder + CTC (extracted from CLI)
├── sensevoice_decoder.cpp        # CTC greedy decode + detokenization
├── vad.cpp                       # FSMN-VAD wrapper (extracted from CLI)
├── format_detect.cpp             # GGUF metadata inspection for format detection
└── libs/
    ├── libfunasr-sensevoice.a    # CMake-built static lib
    ├── libggml.a                 # Rebuilt from pinned llama.cpp
    ├── libggml-base.a
    ├── libggml-cpu.a
    └── libggml-metal.a           # Present but unused in Phase 1
```

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

### Data Flow

```
Audio file (any format)
  → AudioConverter.convertTo16kHzWav()  [Swift, reused]
  → sv_load_model(gguf_path, use_gpu=0)
      → gguf_init_from_file()
      → detect_format(): read metadata keys → {lovemefan|official}
      → load_weights(): QKV split or fused → unified tensor map
      → build_encoder_graph(): ggml graph construction
  → sv_transcribe_segments(wav_path)
      → load_wav_16k_mono()
      → FSMN-VAD segmentation (or fixed-window chunking)
      → for each segment:
          compute_fbank() → [T, 560]
          if lovemefan: apply CMVN else: raw fbank
          encode() → CTC greedy decode → token IDs → detokenize
      → collect segments → sv_result
  → Swift: TranscriptionResult

Model switch:
  sv_free(old_handle) → sv_load_model(new_path) → ready
```

### Format Detection Logic

```
read GGUF tensor names (metadata keys are shared — both formats use "sv.*"):
  if "linear_q_k_v.weight" tensor exists → official format
    → fused QKV mode, raw fbank (no CMVN)
  else if "linear_q.weight" tensor exists → lovemefan format
    → separate QKV mode, apply CMVN
  else → error: unknown format
```

### QKV Projection Handling

```
Official (fused):  load linear_q_k_v.weight [3D, D] → slice into q, k, v at graph build time
Lovemefan (split):  load linear_q.weight + linear_k.weight + linear_v.weight → concat → treat as fused
```

---

## Implementation Units

### U1. Build FunASR runtime as static libraries

**Goal:** 编译 FunASR 官方 SenseVoice runtime 为静态库，生成可被 SPM 链接的 `libfunasr-sensevoice.a` 及配套 `libggml*.a`

**Requirements:** R6

**Dependencies:** None

**Files:**
- Create: `Scripts/build-funasr-libs.sh`
- Modify: `Makefile`
- Create: `Sources/CFunASREngine/libs/` (populated by build script)

**Approach:**
- 编写 shell 脚本 clone modelscope/FunASR（或使用本地 `/tmp/FunASR`），在 `runtime/llama.cpp/` 下 CMake 构建
- 使用 `FETCHCONTENT_SOURCE_DIR_LLAMA=~/workspace/ai/llama.cpp` 指向本地 checkout
- 提取 `llama-funasr-sensevoice` 目标的 object 文件，打包为 `libfunasr-sensevoice.a`
- `libggml*.a` 从构建产物复制到 `Sources/CFunASREngine/libs/`
- Makefile 添加 `funasr-libs` target，`make run-app` 不自动触发（手动步骤）
- 需从 CLI 源码中排除 `main()` 函数，其余 fbank/encoder/CTC/VAD 函数封装为库接口

**Patterns to follow:**
- 当前 `Sources/CAsrEngine/libs/` 预编译 .a 模式
- AGENTS.md: "Pre-built static libs: Sources/CAsrEngine/libs/libggml*.a are Apple Silicon builds. Rebuild from llama.cpp if adding a new backend."

**Test scenarios:**
- Happy path: `make funasr-libs` 成功生成 `libfunasr-sensevoice.a` 和 `libggml*.a`
- Edge case: 本地 llama.cpp checkout 不存在时的错误提示
- Edge case: CMake 构建失败时的错误传播

**Verification:**
- `file Sources/CFunASREngine/libs/libfunasr-sensevoice.a` 确认 arm64 静态库
- `nm libfunasr-sensevoice.a | grep compute_fbank` 确认包含预期符号

---

### U2. Create CFunASREngine SPM target

**Goal:** 创建新 SPM target `CFunASREngine`，包含 C 桥接层和封装后的推理函数，编译通过

**Requirements:** R6, R7

**Dependencies:** U1 (libfunasr-sensevoice.a 就绪)

**Files:**
- Create: `Sources/CFunASREngine/include/funasr_engine.h`
- Create: `Sources/CFunASREngine/funasr_adapter.cpp`
- Create: `Sources/CFunASREngine/fbank.cpp`
- Create: `Sources/CFunASREngine/sensevoice_encoder.cpp`
- Create: `Sources/CFunASREngine/sensevoice_decoder.cpp`
- Create: `Sources/CFunASREngine/vad.cpp`
- Create: `Sources/CFunASREngine/format_detect.cpp`
- Create: `Sources/CFunASREngine/private_headers/` (ggml headers, internal headers)
- Modify: `Package.swift`

**Approach:**
- C API 头文件 `funasr_engine.h` 导出与 `asr_engine.h` 兼容的函数签名
- `funasr_adapter.cpp` 实现: `sv_load_model` (GGUF 加载 + 格式检测 + 图构建)、`sv_transcribe_segments` (VAD + fbank + encode + CTC decode)、`sv_transcribe` (回退纯文本)、`sv_free`、`sv_free_result`
- 从 `/tmp/FunASR/runtime/llama.cpp/sensevoice/funasr-sensevoice/funasr-sensevoice.cpp` 提取: `compute_fbank`、`sanm_layer`/`sanm_attn`、`run_seg` (encoder+CTC)、`detok_sv`、`fftc`、`add_posenc`、`lin`/`lnorm`
- 从 `/tmp/FunASR/runtime/llama.cpp/funasr-vad/funasr-vad.cpp` 提取: FSMN-VAD 函数
- 从 `/tmp/FunASR/runtime/llama.cpp/funasr-common/funasr_audio.h` 提取: `funasr_load_audio_16k_mono` (miniaudio-based)
- `Package.swift`: 新增 `CFunASREngine` target 定义，参照 `CAsrEngine` 的 `cxxSettings` + `linkerSettings` 模式
- 不修改 `VoiceGumServices` 依赖链（U3 再切换）
- `unsafeFlags` 中私有头路径指向 `Sources/CFunASREngine/private_headers`

**Patterns to follow:**
- `Sources/CAsrEngine/include/asr_engine.h` — C API 签名风格
- `Package.swift` CAsrEngine target 的 `cxxSettings` / `linkerSettings` 配置

**Test scenarios:**
- Happy path: `swift build` 成功编译 `CFunASREngine` target
- Edge case: 头文件路径不正确时的编译错误应清晰指向缺失文件

**Verification:**
- `swift build --target CFunASREngine` 通过

---

### U3. Wire CFunASREngine into VoiceGumServices

**Goal:** 将 `CFunASREngine` 接入 `VoiceGumServices`，创建新的 `FunASRTranscriptionService`，支持在 local 引擎间切换

**Requirements:** R3, R5

**Dependencies:** U2

**Files:**
- Create: `Sources/Services/Transcription/FunASRTranscriptionService.swift`
- Modify: `Sources/Services/Transcription/GGMLTranscriptionService.swift` (无功能性改动，加 deprecation 标注)
- Modify: `Package.swift` (VoiceGumServices 添加 CFunASREngine 依赖)
- Modify: `Sources/Core/TranscriptionViewModel.swift` (添加 FunASR 引擎分发)
- Modify: `Sources/Preferences/AppPreferences.swift` (新增 `funasrModel` 等键)
- Modify: `Sources/CLI/main.swift` (可选，支持 `--engine funasr`)

**Approach:**
- `FunASRTranscriptionService` conform `TranscriptionService`，内部调用 `CFunASREngine` 的 C API
- 与 `GGMLTranscriptionService` 共享 `TranscriptionService` 协议，两个 Service 实例不同时持有模型 handle
- `setupTranscriptionService()` 中 `asrProvider == "local"` 时根据 `asrEngine` 偏好值分发到 `GGMLTranscriptionService` 或 `FunASRTranscriptionService`
- 模型切换: `sv_free(old_handle)` 后再 `sv_load_model(new_path)`
- 进度回调: 复用 Unmanaged.passUnretained → `@convention(c)` → DispatchQueue.main.async 模式
- 加 `NSLock` 保护 `svHandle` 访问，避免 U2-U3 线程安全问题

**Patterns to follow:**
- `GGMLTranscriptionService.swift` — 模型生命周期（loadModel/unload/scheduleUnload）、进度回调桥接
- `TranscriptionViewModel.setupTranscriptionService()` — 引擎分发 switch

**Test scenarios:**
- Happy path: 选择 FunASR 引擎，加载 lovemefan GGUF，转录中文音频，返回正确文本及分段
- Edge case: 模型目录不存在时的错误处理
- Error path: 损坏的 GGUF 文件加载失败的错误提示

**Verification:**
- 端到端转录流程: `FunASRTranscriptionService.transcribe(file:language:)` 返回有效 `TranscriptionResult`
- Instruments Leaks 检测: 连续 3 次模型切换无内存增长

---

### U4. SenseVoice dual-format loading

**Goal:** 实现 GGUF 格式自动检测和双格式权重加载，lovemefan 和官方格式共用同一 encoder 推理路径

**Requirements:** R1

**Dependencies:** U2, U3

**Files:**
- Modify: `Sources/CFunASREngine/format_detect.cpp`
- Modify: `Sources/CFunASREngine/funasr_adapter.cpp`
- Modify: `Sources/CFunASREngine/sensevoice_encoder.cpp`

**Approach:**
- 加载 GGUF 时先读取 metadata keys: 检查 `funasr.enc.output_size` vs `sv.output_size` 区分格式
- Lovemefan: 分离式 QKV → 加载 `linear_q.weight/bias` + `linear_k.weight/bias` + `linear_v.weight/bias` → runtime concat 为 `[3D, D]`，推理时 slice
- Lovemefan: 从 GGUF 读取 CMVN means/vars，fbank 后应用 CMVN
- 官方: 融合式 QKV → 直接加载 `linear_q_k_v.weight/bias`，推理时 slice
- 官方: raw fbank，不应用 CMVN
- 两种格式的 encoder 结构完全一致（50+20 SAN-M layers），推理代码共享

**Patterns to follow:**
- `/tmp/FunASR/runtime/llama.cpp/sensevoice/funasr-sensevoice/funasr-sensevoice.cpp` — `load_enc()` 函数、QKV 处理
- CAsrEngine `sense_voice_adapter.cpp` — CMVN 应用逻辑（lovemefan 路径）

**Test scenarios:**
- Happy path: 加载 lovemefan GGUF，检测为 lovemefan 格式，QKV 分离模式，CMVN 启用
- Happy path: 加载官方 GGUF，检测为官方格式，QKV 融合模式，CMVN 禁用
- Edge case: 未知格式 GGUF 的清晰错误提示
- Edge case: GGUF 同时包含两套 metadata key 的歧义处理

**Verification:**
- 两种格式的 `sv_load_model` 均返回非空 handle
- encoder 输出 cosine similarity 验证

---

### U5. Transcription pipeline integration

**Goal:** 实现完整的 fbank → VAD → encode → CTC decode → detokenize 转录流水线，输出 SubtitleSegment 数组

**Requirements:** R3, R4, R7

**Dependencies:** U4

**Files:**
- Modify: `Sources/CFunASREngine/funasr_adapter.cpp`
- Modify: `Sources/CFunASREngine/vad.cpp`
- Modify: `Sources/CFunASREngine/fbank.cpp`
- Modify: `Sources/CFunASREngine/sensevoice_decoder.cpp`
- Modify: `Sources/Services/Transcription/FunASRTranscriptionService.swift`

**Approach:**
- 音频加载: 复用现有 `AudioConverter.convertTo16kHzWav()` → 16kHz mono WAV
- VAD: Phase 1 使用 FSMN-VAD（从 `funasr-vad.cpp` 提取，需要单独的 VAD GGUF 模型 `fsmn-vad.gguf`）。若 VAD 模型不可用，fallback 到固定窗口 chunking（30s 窗口）
- FBank: `compute_fbank()` 纯 C++ 实现，输出 `[T, 560]` row-major float32
- Encoder: SAN-M 50+20 层 ggml graph → CTC head → `[T, V]` logits
- CTC decode: argmax per frame → collapse consecutive → drop blank → token IDs
- Detokenize: SentencePiece decode（lovemefan 有内嵌 vocab，官方 GGUF 同样包含 vocab in metadata）
- 分段: VAD segments → 每个 segment 独立 encode+decode → 组装 `sv_segment[]` + `sv_result`
- 进度回调: 按 VAD segment 进度触发 `asr_progress_fn`（0% → 100% 分段均匀分布）

**Patterns to follow:**
- CAsrEngine `sense_voice_adapter.cpp` — VAD 分段 → 批处理拼接 → `sense_voice_full_with_state` 流程
- CAsrEngine `sense-voice.cc` — 进度回调在 encode 阶段按帧触发

**Test scenarios:**
- Happy path: 30 秒中文录音 → VAD 检测到 3 个语音段 → 每段独立转录 → 返回 3 个分段及合并文本
- Happy path: 静音文件 → VAD 未检测到语音 → 回退到整段纯文本转录
- Edge case: 极短音频（< 1 秒）→ 至少一个 frame 可处理
- Error path: VAD 模型加载失败 → 回退到固定窗口 chunking
- Integration: 用户先加载 lovemefan 模型转录，再切换到官方模型转录，再切回——全程无崩溃、无内存泄漏
- Integration: 官方格式模型转录结果与官方 CLI 输出一致

**Verification:**
- 端到端转录 lovemefan 格式模型 + 中文音频，与当前 CAsrEngine 输出文本逐字对比
- 端到端转录官方格式模型 + 中文音频，与官方 CLI 输出一致

---

### U6. Regression validation

**Goal:** 验证新引擎在 lovemefan 格式上的转录质量不低于 CAsrEngine，确认无回归

**Requirements:** R1 (lovemefan 格式一致性)

**Dependencies:** U5

**Files:**
- Create: `Tests/CFunASREngineTests/RegressionTests.swift`
- Create: `Tests/CFunASREngineTests/Resources/sample_zh.wav`

**Approach:**
- 选取 3 段不同长度和内容的测试音频（短 <10s，中 30s，长 >60s）
- 分别用 CAsrEngine 和新引擎加载同一 lovemefan GGUF，转录同段音频
- 对比: 文本完全一致 or 编辑距离 < 2%（允许浮点精度导致的微小差异）
- 对比: 分段数量和时间戳边界偏差 < 200ms
- 测试 ModelDownloadManager 现有模型目录结构对新引擎的兼容性

**Patterns to follow:**
- 现有 VoiceGum 项目中暂无 ASR 回归测试框架，参照 `docs/brainstorms/2026-05-14-asr-performance-benchmark-results.md` 的评估方法

**Test scenarios:**
- Short audio regression: 10s 中文 → 文本完全一致
- Medium audio regression: 30s 中文 → 编辑距离 < 2%
- Long audio regression: 90s 中文 → 分段数量一致，时间戳偏差 < 200ms
- Edge case: 包含静音段的音频 → 分段行为一致（不产生空段）

**Verification:**
- 所有回归测试用例 PASS

---

### U7. Cleanup — remove CAsrEngine and switch dependency

**Goal:** 验证通过后，将 `VoiceGumServices` 的依赖从 `CAsrEngine` 切换到 `CFunASREngine`，移除 `GGMLTranscriptionService` 的 deprecated 标注

**Requirements:** R6

**Dependencies:** U6 (回归验证通过)

**Files:**
- Modify: `Package.swift` (VoiceGumServices dependencies 替换 CAsrEngine → CFunASREngine)
- Modify: `Sources/Services/Transcription/GGMLTranscriptionService.swift` (import CAsrEngine → import CFunASREngine，移除 deprecated)
- Modify: `Sources/Core/TranscriptionViewModel.swift` (移除旧引擎分发分支，统一为 FunASR)
- Delete: `Sources/CAsrEngine/` (所有源文件、头文件、libs/)
- Modify: `Sources/CLI/main.swift` (更新 import)
- Modify: `Sources/App/AppDelegate.swift` (更新 `asr_engine_init` 调用)
- Modify: `Makefile` (移除 CAsrEngine 相关内容)
- Modify: `AGENTS.md` (更新架构描述和 Known Quirks)

**Approach:**
- 仅在所有回归测试通过后执行
- 保持 `_exit(0)` 绕过 ggml Metal 析构崩溃的变通方案
- 确认 `asr_engine_init()` 等价函数在新引擎中可用
- 确认 CLI 的 `GGMLTranscriptionService.invalidateActiveModel()` 行为一致

**Test scenarios:**
- `swift build -c release` 成功
- `make run-cli` 端到端转录正常
- 无链接器告警（duplicate symbol、undefined symbol）

**Verification:**
- Clean build 通过，无 CAsrEngine 残留引用
- `make run-cli` 转录测试音频成功

---

## System-Wide Impact

- **Interaction graph:** CLI (`VoiceGumCLI` → `VoiceGumServices` → `CFunASREngine`)、GUI (`VoiceGum` → `VoiceGumCore` → `VoiceGumServices` → `CFunASREngine`)。替换对 App/Core/CLI 透明——它们只依赖 `TranscriptionService` 协议
- **Error propagation:** C API 错误通过返回值 + Swift 侧 `guard`/`throw` 转换为 `TranscriptionError.modelNotFound` / `TranscriptionError.transcriptionFailed`
- **State lifecycle risks:** 模型 handle 跨转录调用保持，需确保 `sv_free` 在切换/退出时被调用。`_exit(0)` 继续用于绕过 ggml Metal 析构
- **API surface parity:** `FunASRTranscriptionService` 与 `GGMLTranscriptionService` 共享 `TranscriptionService` 协议，对外接口完全一致（`serviceName` + `transcribe(file:language:)`）
- **Integration coverage:** 端到端测试覆盖 CLI + GUI 两条路径，覆盖 lovemefan + 官方两种格式
- **Unchanged invariants:** `TranscriptionService` 协议不变、`TranscriptionResult` 结构不变、`AudioConverter` 流程不变、`ModelDownloadManager` actor 接口不变、UserDefaults 键前缀 `voicegum.` 不变

---

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| FunASR runtime 的 ggml 版本与预编译 libggml*.a 不兼容 | Med | High | U1 中从同一个 llama.cpp 构建所有 .a 文件，确保版本一致 |
| lovemefan GGUF 的 CMVN 参数在官方 runtime 中行为不同 | Low | Med | U4 中通过格式检测分支处理；U6 回归测试覆盖 |
| FSMN-VAD 分段精度与当前 Silero VAD 差异大 | Med | Med | U5 中保留固定窗口 chunking fallback；Phase 2 可继续使用 Silero VAD |
| ggml Metal 独占——新引擎与 MLX/其他 ggml 消费者冲突 | Low | High | Phase 1 CPU-only 无冲突；Phase 2 Metal 恢复时在同一个 llama.cpp 构建中统一初始化 |
| FSMN-VAD GGUF 模型不可用 | Med | Low | U5 fallback 到固定窗口 chunking，不阻塞核心转录功能 |
| `_exit(0)` 变通在 FunASR runtime 上不再需要或行为不同 | Low | Med | U7 中保持 `_exit(0)` 调用，不替换为 `exit()` |

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-25-funasr-nano-engine-requirements.md](../brainstorms/2026-06-25-funasr-nano-engine-requirements.md)
- FunASR runtime: `modelscope/FunASR/runtime/llama.cpp/` (local clone `/tmp/FunASR`)
- llama.cpp: `~/workspace/ai/llama.cpp`
- Superseded plan: `docs/plans/2026-05-14-003-feat-unified-ggml-asr-engine-plan.md`
- Related: `docs/brainstorms/2026-05-14-asr-performance-benchmark-results.md`
