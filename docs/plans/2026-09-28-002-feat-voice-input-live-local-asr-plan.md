---
title: Live Local ASR Text in Voice Input
type: feat
status: active
date: 2026-09-28
---

# Plan: Live Local ASR Text in Voice Input

## Summary

按住说话的本地引擎路径（SenseVoice / FunASR-Nano）新增实时文本显示：录音期间跑一条增量链路（重采样 → 能量分段 → 单句解码），每识别完一段就把文本追加到悬浮窗，不再等到松键才出结果。实时文本只用于显示，注入仍然只在松键收尾发生一次，内容仍来自现有的整段解码，因此文件转写、注入链路与 `TranscriptionService` 协议都不变。

实时以"段落"为粒度：一句说完（检测到足够静音）就出该句文本，说话过程中不逐字刷新。逐字（增长窗口重解码）列入后续工作。

## Problem Frame

本地引擎的语音输入是"松键后出结果"：录音期间只累积音频缓冲（`Sources/VoiceInput/VoiceInputEngine.swift` 的 `startLocalModel` 与 `accumulate`），松键后写 WAV、整段解码（同文件的 `processFunASR`）。用户在选择 SenseVoice 或 FunASR-Nano 时，整个说话过程悬浮窗里只有波形，没有任何文字反馈，长句子时无法确认说了什么、录音是否正常。系统语音路径没有这个问题，因为 `SFSpeechRecognizer` 提供 partial result 通道（`Sources/VoiceInput/StreamingRecognizer.swift`）。

差异来自模型本身：SenseVoice 是全注意力离线编码器（无 KV cache、无增量位置），FunASR-Nano 的编码器同样吃整段音频。两者都没有 native 流式能力，但都能在"一句话说完"这个粒度上很快给出结果（SenseVoice 的 RTF 约 0.01，见 `docs/brainstorms/2026-05-14-asr-performance-benchmark-results.md`），足以支撑段落级实时显示。

## Requirements

- R1. 本地引擎（SenseVoice / FunASR-Nano）在按住说话期间，已结束语音段的识别文本实时追加到悬浮窗，不再等到松键
- R2. 实时文本只显示，不注入；注入仍只在松键收尾发生一次
- R3. 注入内容仍来自收尾的整段解码，与当前行为一致；实时链路不改变注入结果
- R4. 段落文本上屏后不再改写，实时阶段只追加
- R5. 会话内语言固定：首段确定后，后续段落与收尾解码沿用同一语言值
- R6. 系统语音路径行为不变，仍为流式 partial 上屏
- R7. 既有分支行为不变：模型未下载提示、录音过短取消、Esc 取消、全程无语音、错误提示与 2 秒自动收起
- R8. 60 秒上限与 15 秒 stall watchdog 适配实时路径：持续有段落产出时不得误判为卡死
- R9. 实时文本与波形、引擎配色共存时的悬浮窗展示规则明确，不改变现有尺寸与配色规格

## Scope Boundaries

- 不做逐字实时（增长窗口重解码与稳定门），本期只做段落级
- 不做边说边注入与撤回，注入时机与方式保持现状
- 不改系统语音路径
- 不改文件转写路径与 `TranscriptionService` 协议
- 不改本地模型的加载与空闲卸载语义，不引入常驻预热
- 不引入新的流式 ASR 模型
- 不调整悬浮窗视觉规格（高度、圆角、宽度规则、引擎配色）

### Deferred to Follow-Up Work

- SenseVoice 的逐字实时（增长窗口重解码 + 稳定门 + 可改写尾部）
- FunASR-Nano 段内 token 级上屏
- 用 SenseVoice 自带的 Silero VAD 替换预览侧的能量分段器

## Context & Research

### Relevant Code and Patterns

- `Sources/VoiceInput/VoiceInputEngine.swift` — 本地路径的 `startLocalModel` / `accumulate` / `processFunASR` / `finishStalledRecognition`，实时链路要接入的位置
- `Sources/VoiceInput/AudioCaptureEngine.swift` — `AVAudioEngine` tap（`bufferSize: 1024`，硬件采样率与声道数）与 `onAudioBuffer` 回调约定
- `Sources/VoiceInput/VoiceInputOverlayWindow.swift` — `OverlayViewModel.displayText`、`updateText` 与 `sizeToFitContent`，`OverlayContent` 单行文本布局
- `Sources/VoiceInput/VoiceInputViewModel.swift` — partial 回调接线与悬浮窗生命周期管理
- `Sources/Services/Transcription/FunASRTranscriptionService.swift`、`FunASRNanoTranscriptionService.swift` — 后台队列调用、`isTranscribing` 串行语义、`scheduleUnload` 空闲卸载
- `Sources/CFunASREngine/funasr_adapter.cpp` — `sv_transcribe` 的内部 VAD 与 30 秒批次拼接、语言映射、`wparams` 配置
- `Sources/CFunASREngine/funasr-nano-adapter.cpp` — `nano_transcribe` 的 encoder + LLM 组合与内部 VAD 切分
- `Sources/CFunASREngine/funasr-nano-vad.cpp` — 能量法 VAD 的帧长/步长与最短语音、最短静音常量
- `Sources/Services/Audio/AudioConverter.swift` — 整文件重采样与整文件增益归一化，实时链路不复用

### Institutional Learnings

- `docs/plans/2026-06-29-001-feat-hold-to-talk-voice-input-plan.md` — 语音输入原始设计：明确"不扩展 `TranscriptionService` 协议"，实时状态机与文件转录管道分离
- `docs/plans/2026-09-28-001-feat-voice-input-engine-preference-plan.md` — 优先引擎偏好、本地模型家族解析与降级路径
- `docs/brainstorms/2026-05-14-asr-performance-benchmark-results.md` — SenseVoice RTF 约 0.01，单句解码成本可忽略
- `docs/brainstorms/2026-06-25-funasr-nano-engine-requirements.md` — Nano 44 秒音频约 7 秒（8 线程 CPU），单段解码耗时约为段长的 0.16 倍

### External References

无。两条路径在仓库里都有现成调用范例，不需要外部资料。

## Key Technical Decisions

- **段落级而非逐字级**：预览在段边界产出，一次解码只跑一段。SenseVoice 单句解码成本可忽略，Nano 单段成本与段长成正比但不阻塞收尾
- **显示与注入彻底解耦**：注入仍走收尾的整段解码，实时链路的结果不参与注入，因此预览可以随时丢弃、降级或失败
- **C 侧只加单句解码入口，不加会话状态**：分段、队列、节流都留在 Swift 侧，C 侧只负责"给一段 16k PCM，返回文本"
- **预览分段器独立于模型**：纯信号处理实现，不依赖任何 GGUF 文件，SenseVoice 与 FunASR-Nano 共用同一套分段逻辑，也能在单测里直接跑
- **实时阶段只追加不改写**：段落文本上屏后不再回改；唯一的改写发生在收尾的最终文本刷新
- **会话内语言固定**：首段确定语言后不再重判，避免同一会话内因语言切换导致预览与最终结果整体不一致

## Open Questions

### Resolved During Planning

- 预览是否参与注入：不参与，注入始终来自收尾整段解码
- 分段逻辑放在哪一侧：Swift 侧（C 侧只做单句解码）
- 悬浮窗如何呈现多句文本：单行尾部窗口，保留最近内容
- 系统语音路径是否受影响：不受影响

### Deferred to Implementation

- 能量分段器的阈值常数（噪声底估计、进入/退出双门限）需要在真实麦克风与常见环境下校准
- Nano 首次加载耗时导致的首段预览延迟，需要在真机测量
- 预览文本与最终文本差异的实际量级，需要日志数据支撑后续调优

## Implementation Units

### U1. C 侧单句 PCM 解码入口

**Goal:** 让两个本地引擎在不落盘、不经过内部 VAD 的前提下，对一段 16k 单声道 float PCM 直接返回文本

**Requirements:** R1, R3

**Dependencies:** None

**Files:**
- Modify: `Sources/CFunASREngine/include/funasr_engine.h`
- Modify: `Sources/CFunASREngine/funasr_adapter.cpp`
- Modify: `Sources/CFunASREngine/funasr-nano-adapter.cpp`
- Test: `Tests/CFunASREngineTests/LiveSegmentDecodeTests.swift`

**Approach:**
- 为两只引擎各新增一个单句解码入口：输入为 16k 单声道 float 采样、长度、语言与线程数，返回 malloc 文本（沿用现有 `char *` + 调用方 `free` 的约定）
- SenseVoice 侧复用现有编码路径与 `wparams` 配置，跳过 `silero_vad_with_state` 与批次拼接：分段由 Swift 侧负责，C 侧不做 VAD
- FunASR-Nano 侧复用现有 encoder + LLM 组合，只处理传入的单个音频段，不做内部 VAD 与 30 秒切分
- 复用现有 adapter 文件，不新增 `.cpp`：避免 `Package.swift` 的 `sources` 列表与 `Makefile` 的 `funasr-libs` 构建脚本联动变更
- 空输入或解码失败返回空文本（沿用 Nano 侧 `strdup("")` 的处理方式），调用方统一按空字符串处理

**Patterns to follow:**
- `Sources/CFunASREngine/funasr_adapter.cpp` 中 `sv_transcribe` 的语言映射与 `wparams` 设置
- `Sources/CFunASREngine/funasr-nano-adapter.cpp` 中 `nano_transcribe` 的 encoder + LLM 组合方式
- `Sources/CFunASREngine/include/funasr_engine.h` 的返回与释放约定

**Test scenarios:**
- Happy path：模型可用时，对一段从 WAV 切出的 1–3 秒 PCM 解码 → 返回非空文本
- Edge case：样本数不足一帧 → 返回空文本，不崩溃
- Edge case：空指针句柄或未加载模型 → 返回空文本
- Error path：模型文件缺失 → 加载失败返回空文本，不进入解码
- Test expectation: none for 真实模型下的文本一致性 —— 需要模型文件，按现有 `XCTSkipUnless` 方式跳过

**Verification:**
- `swift test --filter CFunASREngineTests` 通过；无模型环境下相关用例跳过而非失败
- 现有 `sv_transcribe` / `nano_transcribe` 路径的测试保持通过

---

### U2. 增量语音分段器

**Goal:** 把连续的 16k 单声道采样流切成语音段，每段结束时发出事件

**Requirements:** R1, R8

**Dependencies:** None

**Files:**
- Create: `Sources/VoiceInput/StreamingSegmenter.swift`
- Test: `Tests/VoiceGumVoiceInputTests/StreamingSegmenterTests.swift`

**Approach:**
- 纯计算类型，逐帧（25ms 窗、10ms 步长）计算 RMS，维护自适应噪声底与进入/退出两个门限，静音持续达到阈值时长即判定段结束
- 常量沿用现有离线 VAD 的量级（`Sources/CFunASREngine/funasr-nano-vad.cpp` 的 25/10ms 帧、0.3 秒最短语音、0.5 秒最短静音），并额外补充进入与退出两个不同阈值以避免边界抖动
- 段落两端各补一小段 padding，padding 只影响送给解码的样本区间
- 不持有音频、不做 IO、不依赖模型文件；可逐帧喂入，也可一次性喂入
- 该分段器只服务预览显示，与收尾整段解码内部使用的 Silero VAD 相互独立

**Patterns to follow:**
- `Sources/CFunASREngine/funasr-nano-vad.cpp` 的帧长、步长、最短语音与最短静音常量
- `Tests/VoiceGumVoiceInputTests/VoiceInputEngineDecisionTests.swift` 的纯函数测试组织方式

**Test scenarios:**
- Happy path：两段语音 + 中间 0.8 秒静音 → 发出 2 个段事件，边界落在静音区间内
- Edge case：静音只有 0.3 秒 → 不切段，判为同一段
- Edge case：一直没有静音 → 达到最大段长时强制切段
- Edge case：全静音输入 → 不产生段事件
- Edge case：白噪声底较高的输入 → 自适应门限不把噪声判成语音
- Edge case：逐帧喂入与一次性喂入同一段音频 → 事件序列一致

**Verification:**
- 分段器不依赖音频硬件与模型，可在 `swift test` 下直接运行

---

### U3. 实时识别会话驱动器

**Goal:** 把采集到的音频接到分段与单句解码上，产出可显示文本，且不干扰收尾整段解码

**Requirements:** R1, R2, R4, R5, R8

**Dependencies:** U1, U2

**Files:**
- Create: `Sources/VoiceInput/LiveTranscriptionSession.swift`
- Modify: `Sources/VoiceInput/VoiceInputEngine.swift`
- Test: `Tests/VoiceGumVoiceInputTests/LiveTranscriptionSessionTests.swift`

**Approach:**
- 音频 tap 回调里只做入队，重采样与分段在后台串行执行，避免阻塞音频线程
- 重采样使用 `AVAudioConverter` 的流式接口（硬件 44.1/48k → 16k 单声道）；实时链路不做整文件增益归一化，预览侧保持原始电平
- 段落结束时把该段样本交给单句解码（U1）；解码派发到后台队列，最多保留一个在飞任务与一个待处理段，更早的待处理段直接丢弃（只影响预览）
- 文本只追加不改写；语言在首段确定后固定，后续段落与收尾解码沿用同一值
- 会话对象对外只暴露三类事件：段落文本、进行中、结束（含失败原因），不直接接触注入与 UI
- `VoiceInputEngine` 在本地路径启动时创建会话，把同一份音频同时喂给实时链路与既有的 `accumulatedBuffers`（收尾整段解码需要完整音频）

**Patterns to follow:**
- `Sources/VoiceInput/VoiceInputEngine.swift` 现有的 actor 状态机与 `emit*` 回调写法
- `Sources/VoiceInput/AudioCaptureEngine.swift` 的 tap 回调与 `onAudioBuffer` 约定
- `Sources/Services/Transcription/FunASRTranscriptionService.swift` 的后台队列调用与 `isTranscribing` 串行语义

**Test scenarios:**
- Happy path：用假解码器依次喂入三段语音 → 按顺序产出三段文本
- Edge case：解码慢于段到达 → 只保留最新待处理段，中间段被丢弃，音频入队不被阻塞
- Edge case：48k 输入 1 秒 → 重采样输出约 16000 个采样（允许 ±1 帧误差）
- Edge case：会话取消（Esc 或录音过短）→ 停止在飞解码、清空队列、不再产出文本
- Error path：单句解码返回空或失败 → 跳过该段预览，继续处理后续段
- Edge case：`language=auto` 且首段检测到语言 → 后续段落与收尾使用同一语言值

**Verification:**
- 假解码器覆盖队列、取消、重采样与语言固定分支
- 真实模型行为由 U5 的端到端手工验证覆盖

---

### U4. 悬浮窗与状态机接入

**Goal:** 让实时文本在悬浮窗正确呈现，并让语音输入状态机在实时路径上有明确语义

**Requirements:** R1, R4, R6, R8, R9

**Dependencies:** U3

**Files:**
- Modify: `Sources/VoiceInput/VoiceInputOverlayWindow.swift`
- Modify: `Sources/VoiceInput/VoiceInputViewModel.swift`
- Modify: `Sources/VoiceInput/VoiceInputEngine.swift`

**Approach:**
- 悬浮窗文本保持单行，新增尾部窗口规则：显示最近约 40 个字，超出只保留最近内容，波形、配色与宽度计算沿用现有实现
- 更新入口保持追加语义，沿用现有 0.25 秒文本过渡动画
- `.recording` 阶段在收到首段文本前显示"录音中"，收到后显示实时文本；`.recognizing` 仍表示"松键后等待整段解码"
- stall watchdog 改为绑定"是否有新的段落产出"，持续有段落时不触发；60 秒上限与 Esc 取消语义不变
- 系统语音路径不经过新链路，`StreamingRecognizer` 的 partial 沿用现有 `updateText`

**Patterns to follow:**
- `Sources/VoiceInput/VoiceInputOverlayWindow.swift` 的 `updateText` / `sizeToFitContent` 与 `OverlayContent` 布局
- `Sources/VoiceInput/VoiceInputViewModel.swift` 的 partial 回调接线方式

**Test scenarios:**
- Integration：选择 SenseVoice，按住说两句 → 第一句结束后出现第一句文本，第二句结束后追加，松键后注入完整文本（Covers R1, R2）
- Integration：选择 FunASR-Nano → 首段预览在模型加载完成后出现，松键后注入文本与预览一致（Covers R3）
- Edge case：实时文本超过尾部窗口长度 → 只显示最近内容，波形与配色不受影响（Covers R9）
- Edge case：说话过程中出现长静音后继续说话 → 不触发强制收尾（Covers R8）
- Edge case：偏好系统语音 → 行为与升级前一致（Covers R6）
- Test expectation: none for 悬浮窗视觉呈现本身 —— AppKit 面板无测试目标，由上述手工验证覆盖

**Verification:**
- 依次以 SenseVoice 与 FunASR-Nano 跑通"两句以上、含停顿"的完整会话，观察文本逐句出现
- 系统语音路径回归一次，行为不变

---

### U5. 收尾一致性与可观测性

**Goal:** 让注入内容与既有行为一致，并让预览与最终的差异可见、可评估

**Requirements:** R2, R3, R5, R7

**Dependencies:** U3, U4

**Files:**
- Modify: `Sources/VoiceInput/VoiceInputEngine.swift`
- Modify: `Sources/VoiceInput/VoiceInputViewModel.swift`

**Approach:**
- 收尾仍走现有路径：写 WAV → 整段解码 → 注入；实时链路的结果不参与注入
- 整段解码使用会话固定的语言值；会话未产出任何语音段时沿用偏好里的语言设置
- 收尾时把最终文本刷新到悬浮窗（在现有退场动画之前），让最后可见的一帧与注入内容一致
- 会话结束记录一条日志：引擎、模型、段数、预览与最终文本是否一致、差异字符数
- 模型未下载、录音过短、Esc 取消、全程无语音的既有分支保持原行为与提示

**Patterns to follow:**
- `Sources/VoiceInput/VoiceInputEngine.swift` 现有的 `processFunASR` / `handleFinalText` / `cleanup`
- `Sources/Services/Transcription/Logger.swift` 的日志写法

**Test scenarios:**
- Integration：按住说三句后松键 → 注入内容等于收尾整段解码结果，日志记录预览与最终是否一致
- Integration：实时链路中途失败（例如解码返回空）→ 仍能正常注入整段解码结果
- Edge case：按下后立刻松开（低于最小时长）→ 无实时文本、无注入
- Edge case：按住但全程无语音 → 无注入，悬浮窗按现有路径收起
- Edge case：模型未下载 → 沿用现有提示与结束路径，不进入实时链路

**Verification:**
- SenseVoice 与 FunASR-Nano 各跑一次完整会话，核对注入文本与日志
- 短按、Esc、无语音、模型未下载四条边界路径与升级前一致

---

## System-Wide Impact

- **Interaction graph:** 本地路径新增一条并行链路（采集 → 分段 → 单句解码 → 悬浮窗），收尾路径与系统语音路径不变；`TranscriptionViewModel` 与 `ASRSettingsTab` 完全不受影响
- **Error propagation:** 实时链路的错误只影响预览文本，不进入 `VoiceInputState.error`；会话级失败仍走现有错误路径
- **State lifecycle risks:** 首次解码从松键后提前到录音期间，模型加载时间会出现在按住之后的头几百毫秒（SenseVoice 约 0.17 秒）；空闲卸载与懒加载语义不变
- **API surface parity:** 新增 C 入口与 Swift 会话类型留在模块内，`TranscriptionService` 协议不动
- **Integration coverage:** 分段器与会话驱动器可单测；引擎与悬浮窗的联动只能手工验证
- **Unchanged invariants:** 注入时机与方式、系统语音 partial 通道、文件转写链路、模型懒加载与空闲卸载、悬浮窗尺寸与配色规则

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| 能量分段器在嘈杂或小声环境下切段偏碎、偏晚 | 只影响预览可读性；收尾整段解码仍使用 Silero VAD，注入结果不变；常量可调，后续可换用 SenseVoice 的 Silero VAD 会话 |
| FunASR-Nano 首次加载耗时，首段预览延迟出现 | 加载期间音频照常保留用于收尾解码；加载完成后继续产出后续段落 |
| 解码排队堆积导致预览滞后于说话 | 队列上限 1，丢弃中间待处理段，只保证最新段落 |
| 预览文本与最终注入文本不一致 | 收尾把最终文本刷到悬浮窗，并记录差异字符数，作为后续调优输入 |
| 实时链路带来额外耗电 | 只在段边界触发解码，成本与说话量成正比（SenseVoice RTF 约 0.01） |
| 与文件转写并发触发 ggml Metal 独占问题 | 沿用现有 `isTranscribing` 串行等待与 `invalidateActiveModel()` 语义，实时链路不新建第二个 Metal 消费者 |
| C 侧新增入口影响现有解码路径 | 新入口与 `sv_transcribe` / `nano_transcribe` 并存，后者不改动，现有测试继续覆盖 |

## Sources & References

- Related plan: `docs/plans/2026-06-29-001-feat-hold-to-talk-voice-input-plan.md`
- Related plan: `docs/plans/2026-09-28-001-feat-voice-input-engine-preference-plan.md`
- Related brainstorm: `docs/brainstorms/2026-06-29-hold-to-talk-voice-input-requirements.md`
- Benchmark: `docs/brainstorms/2026-05-14-asr-performance-benchmark-results.md`
- Related code: `Sources/VoiceInput/`, `Sources/CFunASREngine/include/funasr_engine.h`, `Sources/Services/Transcription/FunASRTranscriptionService.swift`
