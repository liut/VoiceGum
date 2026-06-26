---
date: 2026-06-25
topic: funasr-nano-engine
---

# FunASR-Nano 引擎支持

## Summary

用 FunASR 官方 C++ GGUF runtime（modelscope/FunASR `runtime/llama.cpp/`）替换当前 CAsrEngine，获得 SenseVoice + FunASR-Nano 双模型能力。SenseVoice 需同时兼容 lovemefan（分离式 QKV + CMVN）和官方（融合式 QKV + raw fbank）两种 GGUF 格式。Phase 1: SenseVoice 双格式兼容验证；Phase 2: FunASR-Nano 集成。先 CPU 验证可行性。

---

## Problem Frame

VoiceGum 当前仅支持 SenseVoice Small 模型（lovemefan GGUF 格式），语言覆盖限制为中文、英文、日文、韩文四种。用户需要转录法语、德语、西班牙语等多语言音频时完全不可用。

FunASR-Nano 是阿里 FunAudioLLM 团队发布的端到端 LLM-based ASR 模型（SenseVoice SAN-M encoder + adaptor + Qwen3-0.6B LLM decoder），原生支持 31 种语言。modelscope/FunASR 仓库的 `runtime/llama.cpp/` 目录提供了完整的 C++ GGUF 运行时，支持 SenseVoiceSmall、Paraformer、FunASR-Nano 三个模型，共享同一套 SAN-M encoder / FSMN / fbank 实现。

替换为官方统一运行时后，一套引擎同时驱动轻量 CTC 模型（SenseVoice）和 LLM-based 多语言模型（FunASR-Nano），从根本上解决语言覆盖问题。

---

## Actors

- A1. **最终用户**: 拖入音频文件，选择语言，获得转录结果。当前受限于 4 种语言，需要更多语言支持。
- A2. **ASR 引擎**: 负责模型加载、音频预处理、推理、结果输出的 C/C++ 组件，通过 C 桥接层暴露给 Swift。
- A3. **VoiceGum App**: 管理模型下载、引擎生命周期、转录任务调度和 UI 状态。

---

## Key Flows

- F1. **模型发现与加载**
  - **Trigger:** 用户手动放置 GGUF 文件到模型目录，或 App 启动时扫描已有模型
  - **Actors:** A3
  - **Steps:** 引擎扫描本地模型目录 → 发现 GGUF 文件 → 检测格式（QKV 模式 + CMVN 模式）→ 加载模型权重
  - **Outcome:** 模型就绪，可被转录流程使用
  - **Covered by:** R1

- F2. **多语言音频转录**
  - **Trigger:** 用户选择引擎，拖入音频文件
  - **Actors:** A1, A2, A3
  - **Steps:** App 加载音频 → 引擎执行 fbank 特征提取 → 根据模型格式选择预处理路径（CMVN / raw）→ SAN-M 编码 → 解码 → VAD 语音分段 → 返回带时间戳的分段文本
  - **Outcome:** 用户获得准确的转录结果，包含按语音段分割的文本和时间戳
  - **Covered by:** R3, R4

- F3. **模型切换**
  - **Trigger:** 用户在模型之间切换
  - **Actors:** A3, A2
  - **Steps:** 卸载当前模型资源 → 加载目标模型 GGUF → 检测格式（QKV 模式 + CMVN 模式）→ 更新引擎状态
  - **Outcome:** 后续转录使用新选择的模型
  - **Covered by:** R5

---

## Requirements

**模型支持**
- R1. 引擎支持加载 SenseVoiceSmall GGUF 模型，自动检测并适配两种格式：lovemefan（分离式 QKV + CMVN）和官方 FunAudioLLM（融合式 QKV + raw fbank）
- R2. 引擎支持加载 FunASR-Nano 的 encoder + LLM 两个 GGUF 文件（Phase 2）

**转录能力**
- R3. 支持从音频文件进行离线整段转录
- R4. 转录结果包含文本内容，分段信息由 VAD 提供

**集成约束**
- R5. 支持模型切换，切换时正确释放旧模型资源
- R6. 从官方 CLI 源码提取核心推理函数，封装为 C 桥接层暴露给 Swift
- R7. 引擎支持进度回调，使 UI 能展示转录进度

---

## Acceptance Examples

- AE1. **Covers R1.** Given 现有用户的 lovemefan 格式 `sense-voice-small-q8_0.gguf` 和一段中文录音, when 调用转录接口, 引擎自动检测格式（分离式 QKV + CMVN）并返回正确转录结果，与当前 CAsrEngine 输出一致。
- AE2. **Covers R1.** Given 官方格式 SenseVoiceSmall GGUF 和同一段中文录音, when 调用转录接口, 引擎自动检测格式（融合式 QKV + raw fbank）并返回正确转录结果。
- AE3. **Covers R5.** Given 已加载 lovemefan 格式模型, when 切换到官方格式模型并触发转录, 引擎先释放旧模型资源再加载新格式，转录使用新模型完成。

---

## Success Criteria

- 现有 lovemefan 格式 SenseVoice 转录功能无回归——相同音频文件产生相同的文本输出
- 官方格式 SenseVoiceSmall GGUF 转录功能正常——与官方 CLI 输出一致
- 模型切换连续 3 次无内存泄漏或挂死
- Phase 1 CPU 性能目标：典型 5 分钟中文音频的端到端转录耗时 < 30 秒（RTF < 0.1）
- Phase 2: FunASR-Nano 端到端转录流程无崩溃
- Phase 2 准确率目标：FunASR-Nano 在中文、英文、日文、法文上的 CER/WER 与官方 benchmark 偏差 < 5%

---

## Scope Boundaries

- 不包含 Metal GPU 加速——Phase 1 仅验证 CPU 推理可行性。Metal 在 Phase 2 期间或之后作为独立任务恢复
- 不包含流式/实时识别——仅支持离线整段转录
- 不包含 hotword 热词定制、情感检测、语种自动识别
- 不包含模型的自动下载集成（手动放置 GGUF 文件即可验证）。F1 描述的是加载流程，自动下载属于远期规划
- 不修改 SwiftUI 界面——先在最小测试路径验证
- FunASR-Nano 集成属于 Phase 2，Phase 1 聚焦 SenseVoice 双格式兼容

---

## Architecture Decision: Replace vs Add-Alongside

VoiceGum 现有架构已支持多 ASR 引擎并存——`GGMLTranscriptionService`、`OnlineAPITranscription`、`VolcanoEngineASR` 均 conform `TranscriptionService` 协议，在 `setupTranscriptionService()` 中 dispatch。理论上 FunASR-Nano 可作为第四个独立 `TranscriptionService` 加入，无需替换现有引擎。

选择 **替换** 而非 **增量添加** 的理由：

- **ggml 版本统一**: 当前 CAsrEngine 和 FunASR runtime 各自依赖不同的 ggml/llama.cpp 版本，共存时有符号冲突风险。替换可消除版本分化
- **SenseVoice 长期维护**: 官方 runtime 的 SenseVoice 实现已通过 PyTorch 精度校验（encoder cosine 1.0, CTC ids identical），且与 FunASR-Nano 共享同一 SAN-M encoder 代码，避免维护两套 SenseVoice 实现
- **模型生态统一**: 官方 runtime 支持 SenseVoice + Paraformer + FunASR-Nano + FSMN-VAD 全系列，未来扩展新模型（如 Paraformer）无需额外集成工作

增量方案的 risk 在于 ggml 版本冲突和双倍维护成本。替换方案的 risk 在于 Phase 1 无用户可见价值且全量替换有回归风险。当前选择替换路线，Plan 阶段需重点评估 ggml 版本共存可行性——如果验证发现可安全共存，增量方案始终可作为 fallback。

---

## Key Decisions

- **Phase 1 SenseVoice 双格式兼容，Phase 2 FunASR-Nano**: 先确保现有能力零回归，再扩展新能力
- **同时支持 lovemefan 和官方两种 GGUF 格式**: 保护现有用户投资，避免强制迁移
- **提取官方 runtime 为库而非从零实现**: 官方 runtime 已通过 PyTorch 精度校验（encoder cosine 1.0, CTC ids identical），质量有保证
- **CPU 先行验证**: 降低 Phase 1 复杂度，Metal 作为独立后续任务

---

## 格式兼容性验证结果

通过编译官方 CLI 并对 lovemefan GGUF 做 tensor 名分析，确认：

| 差异维度 | lovemefan | 官方 FunAudioLLM |
|---|---|---|
| QKV 投影 | 分离式: `linear_q` / `linear_k` / `linear_v`（3 tensor） | 融合式: `linear_q_k_v`（1 tensor） |
| CMVN | 应用 CMVN 归一化 | raw fbank（不应用） |
| Tensor 命名前缀 | `encoder.encoders0.0.*` / `encoder.encoders.*` | `encoder.encoders0.0.*` / `encoder.encoders.*` |
| FSMN 命名 | `fsmn_block.weight` | `fsmn_block.weight` |

两种格式的差异集中在 QKV 投影和 CMVN 处理两项，可通过加载时检测 + 推理时分支解决，不需要两套 encoder 代码。

---

## Dependencies / Assumptions

- **已验证**: FunASR 官方 runtime 位于 `modelscope/FunASR/runtime/llama.cpp/`，CMake 构建成功
- **已验证**: `FETCHCONTENT_SOURCE_DIR_LLAMA` 参数可用，已通过本地 `~/workspace/ai/llama.cpp` 构建，Metal backend 被检测到
- **已验证**: lovemefan GGUF 与官方 CLI 的差异为 QKV 投影方式（分离 vs 融合）+ CMVN 处理，非容器格式不兼容
- **已验证**: Runtime 当前为 CLI 工具形态（独立 `main()` 函数），需提取核心函数为可复用 C 库
- **假设**: 官方 SenseVoiceSmall GGUF 可从 HuggingFace `FunAudioLLM/SenseVoiceSmall-GGUF` 下载
- **假设**: FunASR-Nano GGUF 可从 HuggingFace `FunAudioLLM/Fun-ASR-Nano-GGUF` 下载
- **假设**: 构建时将使用本地 `~/workspace/ai/llama.cpp` checkout（通过 `FETCHCONTENT_SOURCE_DIR_LLAMA`），避免 FunASR runtime 的 pinned tag 与预编译 `libggml*.a` 版本不一致
- **缓解**: 若 GGUF 文件不可用，需自行转换（官方提供 `convert-funasr-to-gguf.py` 和 `export_sensevoice_gguf.py`），工作量需在 Plan 阶段评估

---

## Outstanding Questions

### Deferred to Planning

- [Affects R6][Technical] 如何将 CLI 源码重构为可分发的 C 库——直接提取函数 vs 保留独立 CMake target vs 子模块引入
- [Affects R1][Technical] 双格式自动检测策略——通过 GGUF metadata key 区分还是通过 tensor 名探测
- [Affects R6][Technical] llama.cpp 的 Metal 后端与此 runtime 的 ggml 版本兼容性——已验证 Metal backend 在构建时检测到，但需验证运行时 GPU 推理正确性
- [Affects R3][Needs research] FunASR-Nano 在 Apple Silicon CPU 上的推理速度——44s 音频参考耗时 ~7s（8 线程），实际体验需实测
- [Affects R3][Needs research] 官方 GGUF 模型的 ModelScope 镜像可用性（国内下载速度）
- [Needs user decision] FunASR-Nano vs whisper.cpp 作为多语言方案——whisper.cpp 支持 99+ 语言，使用与当前 CAsrEngine 相同的 ggml Metal 后端，是增量方案而非替换。需要用户决策是否在评估时纳入 whisper.cpp 作为替代方案

### 关联文档

- `docs/plans/2026-05-14-003-feat-unified-ggml-asr-engine-plan.md`: 已有的 CAsrEngine 统一计划，目标用上游 llama.cpp 替换。本文档选择 FunASR runtime 路径（而非上游 llama.cpp），原因是官方 runtime 提供原生 FunASR-Nano + SenseVoice + Paraformer 多模型支持
