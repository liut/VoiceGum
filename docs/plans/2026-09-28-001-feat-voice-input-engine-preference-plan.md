---
title: Voice Input Engine Preference
type: feat
status: completed
date: 2026-09-28
origin: docs/brainstorms/2026-09-28-voice-input-engine-preference-requirements.md
---

# Plan: Voice Input Engine Preference

## Summary

语音输入新增「优先引擎」偏好（系统语音 / SenseVoice / FunASR-Nano，默认系统语音）。引擎选择不再由 `VoiceInputEngine` 里的硬编码授权与语言判定决定，而是由偏好驱动：首选引擎可用即用首选，首选为系统语音但不可用时静默降级到已下载的本地模型，首选为本地模型但未下载时明确提示下载。决策逻辑抽成纯函数并配回归测试。

---

## Problem Frame

语音输入的引擎优先级写死在 `Sources/VoiceInput/VoiceInputEngine.swift` 里，用户想让音频不出本机、或想用某个特定本地模型，唯一办法是把识别语言改成一个系统语音不支持的语言来触发降级。完整问题描述见 origin。

---

## Requirements

- R1. 设置 → 通用 → 语音输入 中新增「优先引擎」选择：系统语音、SenseVoice、FunASR-Nano，默认系统语音
- R2. 该项仅在「语音输入」开关打开时可见，与触发键设置同级
- R3. 选择结果持久化，重启应用后保持
- R4. 该设置只作用于语音输入，不影响文件转写页的引擎与模型选择
- R5. 首选引擎可用时，语音输入会话必须使用该引擎
- R6. 首选为系统语音但不可用时，静默降级到已下载的本地模型，不弹错误提示
- R7. 首选为本地模型但该模型未下载时，提示前往设置下载并结束本次会话，不静默改用其他引擎
- R8. 首选为本地模型且模型已下载时，按用户指定的模型族运行，不再按固定顺序在本地模型之间挑选
- R9. 悬浮窗继续以现有配色区分「系统语音」与「本地模型」

**Origin actors:** A1 (用户), A2 (VoiceGum App), A3 (引擎：系统语音 / SenseVoice / FunASR-Nano)
**Origin flows:** F1 (指定优先引擎), F2 (首选可用时的语音输入), F3 (首选不可用)
**Origin acceptance examples:** AE1 (covers R1, R5), AE2 (covers R3), AE3 (covers R6), AE4 (covers R7), AE5 (covers R4)

---

## Scope Boundaries

- 不统一语音输入与文件转写的模型设置
- 不做本地模型预热或常驻
- 不做按语言或内容自动选择引擎的路由
- 不把在线 ASR（Whisper / 火山引擎）引入语音输入
- 不改变系统语音是否使用设备端识别的行为
- 录音中途系统语音失败不做中途降级：系统语音路径不缓存音频，切换引擎等于丢掉这段录音，维持现有错误提示行为

---

## Context & Research

### Relevant Code and Patterns

- `Sources/VoiceInput/VoiceInputEngine.swift` — `startRecording()` 现在的引擎判定（授权 + locale 支持 → 系统语音，否则本地），`findBestLocalModel()` 的本地模型发现，`switchToFunASR()` 的降级入口，`emitEngine()` 的悬浮窗配色来源
- `Sources/VoiceInput/StreamingRecognizer.swift` — `authorizationStatus`、`requestAuthorization()`、`resolveLocale(for:)`，决策所需的系统语音可用性输入
- `Sources/Services/Transcription/ModelDownloadManager.swift` — `allModels`（`sense-voice-*` 与 `funasr-nano`）与 `nonisolated func isModelDownloaded(_:)`，判断某个模型族是否已有可用模型
- `Sources/Services/Transcription/FunASRTranscriptionService.swift`、`FunASRNanoTranscriptionService.swift` — 两个本地引擎的 `transcribe(file:language:)` 入口与懒加载行为
- `Sources/Preferences/AppPreferences.swift` — `Keys` 常量 + 计算属性写法，`sanitizeProvider()` 是"读取时校验陈旧值并回退默认值"的既有先例
- `Sources/Core/SettingsView.swift` — `GeneralSettingsTab` 的语音输入区块：开关 + 条件渲染的触发键 Picker + `onChange` 持久化
- `Sources/VoiceInput/WaveformView.swift` — `VoiceInputASREngine` 二态配色（系统语音暖黄 / 本地绿色）

### Institutional Learnings

- `docs/plans/2026-06-29-001-feat-hold-to-talk-voice-input-plan.md` — 语音输入的原始设计：U5 的引擎降级、U8 的偏好项与设置区块写法，以及"FunASR 降级走松键后离线识别"的既有约束
- `docs/brainstorms/2026-05-14-asr-performance-benchmark-results.md` — 本地两个引擎的代价差异：SenseVoice 加载 0.17s、RTF 0.01，FunASR-Nano 走 LLM 自回归解码
- `docs/brainstorms/2026-05-15-app-idle-model-unload-requirements.md` — 本地模型懒加载与空闲卸载的既有语义，本计划不改变

### External References

无。系统语音与本地模型两条路径在仓库里都有现成调用范例，不需要外部资料。

---

## Key Technical Decisions

- **偏好值按引擎家族划分**：选项为 `systemSpeech` / `senseVoice` / `funASR` 三值；SenseVoice 家族内部的具体量化版本（q8_0 / fp16 / fp32）沿用现有自动挑选，避免在语音输入里再暴露一层配置
- **决策逻辑抽成纯函数**：把"偏好 + 系统语音可用性 + 已下载本地模型"映射为"这次用哪个引擎 / 为什么用不了"的判定独立出来，`VoiceInputEngine` 只消费结果，使降级分支可被单测覆盖
- **降级判定发生在会话开始**：授权状态、locale 支持、本地模型是否已下载都在按下触发键时判定；录音中途的识别失败维持现有 `VoiceInputState.error` 行为
- **不做静默替换**：首选为本地模型但未下载时走 `VoiceInputError.modelNotDownloaded`，复用现有悬浮窗错误展示与 2 秒自动收起
- **偏好本地时不申请系统语音授权**：现有实现在每次会话开始都会申请 SFSpeech 授权，改为仅在偏好为系统语音时申请，避免为用户不使用的引擎弹权限
- **悬浮窗维持二态配色**：不新增区分 SenseVoice 与 FunASR-Nano 的第三种颜色，实际使用的具体模型通过日志核对

---

## Open Questions

### Resolved During Planning

- 系统语音"不可用"的判定时机：会话开始时判定授权与 locale 支持，加上 `StreamingRecognizer` 创建或启动失败时降级（对应现有的 `switchToFunASR` 入口）；录音中途失败不降级
- 首选为本地模型但该家族一个模型都没下载：直接走 `modelNotDownloaded` 提示，不跨家族替换，也不回退系统语音
- 偏好项的取值形式：字符串枚举，读取时校验非法或陈旧值并回退 `systemSpeech`

### Deferred to Implementation

- SenseVoice 家族内挑选具体模型时是否需要继续沿用现有目录扫描顺序：[Why] 需要在实际目录状态与模型文件命名下确认，规划阶段无法验证
- 决策结果为本地路径时是否需要额外的 `invalidateActiveModel()` 协调：[Why] 需要观察与文件转写并发时 Metal 后端的实际行为

---

## Implementation Units

### U1. 优先引擎偏好与决策逻辑

**Goal:** 提供持久化的优先引擎偏好，以及一个可单测的纯函数把偏好与可用性映射为本次会话的引擎决策，并为语音输入模块建立测试目标

**Requirements:** R1, R3, R5, R6, R7, R8

**Dependencies:** None

**Files:**
- Create: `Sources/VoiceInput/VoiceInputEnginePreference.swift`
- Modify: `Sources/Preferences/AppPreferences.swift`
- Modify: `Package.swift`
- Test: `Tests/VoiceGumVoiceInputTests/VoiceInputEngineDecisionTests.swift`

**Approach:**
- 新文件承载一个偏好枚举（三值，含界面显示名）与一段纯决策逻辑：输入偏好、系统语音是否可用、已下载的本地模型集合，输出"用系统语音 / 用某个本地家族 / 不可用及原因"
- 不可用原因至少区分"本地模型未下载"，以便复用现有错误提示
- `AppPreferences` 增加语音输入区块下的新键与计算属性，默认 `systemSpeech`，读取时校验取值合法性并回退默认值（沿用 `sanitizeProvider()` 的写法）
- 新增 `VoiceGumVoiceInputTests` testTarget 依赖 `VoiceGumVoiceInput`；被测试的决策逻辑不依赖音频硬件与 AppKit 运行环境

**Patterns to follow:**
- `Sources/Preferences/AppPreferences.swift` 的 `Keys` + 计算属性 + 读取时校验
- `Tests/VoiceGumServicesTests/SRTTranslationManagerTests.swift` 的测试组织方式

**Test scenarios:**
- Happy path: 偏好系统语音 + 已授权 + 语言受支持 → 决策为系统语音
- Happy path: 偏好 SenseVoice + 已下载 `sense-voice-fp16` → 决策为本地 SenseVoice 家族
- Happy path: 偏好 FunASR-Nano + 已下载 `funasr-nano` → 决策为本地 FunASR-Nano 家族
- Error path: 偏好系统语音 + 未授权（或语言不受支持）+ 至少一个本地模型已下载 → 决策为本地家族，且不报错
- Error path: 偏好系统语音 + 不可用 + 没有任何本地模型 → 决策为不可用，原因为模型未下载
- Error path: 偏好 FunASR-Nano + 未下载该模型但 SenseVoice 已下载 → 决策为不可用，原因为模型未下载（不跨家族替换）
- Edge case: 偏好值为非法或陈旧字符串 → 回退系统语音行为
- Edge case: 偏好本地家族 + 系统语音同时不可用（未授权）→ 决策仍为本地家族

**Verification:**
- 决策分支全部由测试覆盖，新增 testTarget 在 `swift test` 下可运行
- 偏好默认值在未写入任何 UserDefaults 时为系统语音

---

### U2. VoiceInputEngine 接入引擎决策

**Goal:** 让语音输入会话按偏好决策选择引擎，本地路径按用户指定的模型族解析模型，缺模型时给出可执行的提示

**Requirements:** R5, R6, R7, R8, R9

**Dependencies:** U1

**Files:**
- Modify: `Sources/VoiceInput/VoiceInputEngine.swift`

**Approach:**
- `startRecording()` 改为消费 U1 的决策结果：系统语音 → 现有 `startSFSpeech()` 路径；本地 → 按决策给出的家族解析具体模型；不可用 → 以 `VoiceInputError.modelNotDownloaded` 结束会话
- 现有 `findBestLocalModel()` 的发现逻辑改为按家族解析，SenseVoice 家族沿用现有目录扫描与文件后缀判定，FunASR-Nano 沿用 `funasr-nano` 目录判定
- 保留现有降级入口语义：系统语音授权被拒、locale 不受支持、`StreamingRecognizer` 创建或启动失败时降级到本地模型（前提是本地有已下载模型）
- 保留 `emitEngine()` 的二态配色输出：系统语音 → `.systemSpeech`，任一本地家族 → `.offlineModel`
- 会话开始时记录一条日志，写明偏好、决策结果与实际使用的引擎及模型，供用户核对 R5
- 系统语音授权申请改为只在偏好为系统语音时触发；偏好为本地模型时直接判定本地模型可用性，不弹授权请求

**Patterns to follow:**
- `Sources/VoiceInput/VoiceInputEngine.swift` 现有的 `startSFSpeech()` / `startFunASR()` / `switchToFunASR()` 分工
- `Sources/Services/Transcription/Logger.swift` 的日志写法

**Test scenarios:**
- Integration: 偏好 SenseVoice 且模型已下载，按住触发键说话 → 波形为本地配色，日志显示使用 SenseVoice 家族模型，文本注入成功（Covers AE1）
- Integration: 偏好 FunASR-Nano 但该模型未下载 → 悬浮窗显示"离线模型未下载，请前往设置下载"，不注入文本，录音不会送到 Apple 服务器（Covers AE4）
- Integration: 偏好系统语音 + 语音识别不可用 + 本地模型已下载 → 静默降级，悬浮窗为本地配色，文本正常注入（Covers AE3）
- Integration: 偏好保持默认（系统语音）→ 行为与升级前一致
- Edge case: 偏好 SenseVoice 但只下载了 `funasr-nano` → 提示模型未下载，不自动改用 FunASR-Nano
- Edge case: 偏好 SenseVoice 且系统语音授权为未决定状态 → 不弹授权请求，直接使用本地模型

**Verification:**
- 三种偏好各自跑通一次完整录音→注入流程
- 服务端未下载模型的场景给出提示且不产生任何注入副作用

---

### U3. 设置界面暴露优先引擎选项

**Goal:** 让用户在设置里选择优先引擎，且改动立即持久化

**Requirements:** R1, R2, R3, R4

**Dependencies:** U1

**Files:**
- Modify: `Sources/Core/SettingsView.swift`

**Approach:**
- 在 `GeneralSettingsTab` 的语音输入区块内、触发键 Picker 同级位置增加「优先引擎」Picker，展示三个选项的显示名
- 沿用现有条件渲染：仅在「语音输入」开关打开时出现；沿用现有 `onChange` 直接写入 `AppPreferences` 的持久化方式
- 不改动 `ASRSettingsTab` 的任何引擎或模型选择逻辑（对应 R4）

**Patterns to follow:**
- `Sources/Core/SettingsView.swift` 中触发键 Picker 的条件渲染与 `onChange` 写法

**Test scenarios:**
- Happy path: 打开语音输入开关 → 出现「优先引擎」选项；切换为 SenseVoice → `AppPreferences` 值更新
- Edge case: 关闭语音输入开关 → 优先引擎选项随触发键一起隐藏，已保存的偏好不被清除
- Integration: 切换偏好后按住触发键录音 → 使用新引擎（与 U2 的手工验证合并执行）（Covers AE2, AE5）
- Test expectation: none for UI 绑定本身 —— `Sources/Core` 无测试目标，其行为通过上述手工验证覆盖

**Verification:**
- 设置页可切换三个选项，重启应用后选择保持
- 文件转写页的引擎与模型选择不受影响

---

## System-Wide Impact

- **Interaction graph:** `VoiceInputEngine.startRecording()` 的全部入口路径改变引擎判定来源；文件转写（`TranscriptionViewModel` / `ASRSettingsTab`）不受影响
- **Error propagation:** 新增的不可用分支复用 `VoiceInputState.error` → `VoiceInputViewModel.handleStateChange` → 悬浮窗错误文案与 2 秒自动收起
- **State lifecycle risks:** 本地路径仍是每会话新建 service 实例并懒加载模型（按需求明确不做常驻），决策层不改变模型生命周期
- **API surface parity:** `VoiceGumVoiceInput` 新增的偏好枚举与决策类型保持模块内可见，不扩散到 Core/Services 的公开接口
- **Integration coverage:** 单测覆盖决策分支，但"偏好 → 实际识别引擎 → 注入文本"的链路只能靠手工录音验证
- **Unchanged invariants:** 触发键监听与文本注入机制、悬浮窗二态配色协议、文件转写页的引擎选择、本地模型懒加载与空闲卸载语义

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| 用户把偏好切到本地模型但只下载了另一个家族，每次录音都提示未下载 | 提示文案直接指向设置页下载；这是 R7 明确要求的行为，不做静默替换 |
| 偏好改动被误认为对正在进行的会话立即生效 | 偏好只在下次按下触发键时读取；如需在界面说明，属可选文案补充 |
| 新增 testTarget 改变包结构，影响既有构建流程 | testTarget 仅依赖 `VoiceGumVoiceInput`，不引入新依赖；构建命令不变 |
| 决策逻辑与 `VoiceInputEngine` 实际行为漂移（决策通过但引擎走了别的路径） | U2 的日志记录实际引擎，手工验证时与决策一并核对 |

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-09-28-voice-input-engine-preference-requirements.md](docs/brainstorms/2026-09-28-voice-input-engine-preference-requirements.md)
- Related plan: [docs/plans/2026-06-29-001-feat-hold-to-talk-voice-input-plan.md](docs/plans/2026-06-29-001-feat-hold-to-talk-voice-input-plan.md)
- Related code: `Sources/VoiceInput/VoiceInputEngine.swift`, `Sources/Preferences/AppPreferences.swift`, `Sources/Core/SettingsView.swift`
