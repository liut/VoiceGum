---
date: 2026-06-29
topic: hold-to-talk-voice-input
type: feat
origin: docs/brainstorms/2026-06-29-hold-to-talk-voice-input-requirements.md
status: active
---

# Plan: Hold-to-Talk Voice Input

## Summary

新增按住说话（Hold-to-Talk）语音输入功能：按住可配置触发键录音，松开后通过模拟粘贴将转录文字注入当前焦点输入框。优先使用 Apple SFSpeechRecognizer 流式转录，语言不支持时降级到 FunASR-Nano 离线识别。录音时屏幕底部居中显示胶囊状悬浮窗，包含实时 RMS 波形和流式转录文本。

## Problem Frame

VoiceGum 目前仅支持文件级离线转录。用户在即时通讯、文档编辑场景中需要先录音保存文件再拖入应用等待识别，流程中断心流。本功能将语音输入压缩为"按住→说话→松开"一个动作，识别结果直接出现在编辑位置。

（完整问题描述见 origin: docs/brainstorms/2026-06-29-hold-to-talk-voice-input-requirements.md）

---

## Key Technical Decisions

- **独立 VoiceGumVoiceInput 模块** — 不扩展 TranscriptionService 协议。语音输入的实时状态机（按下→录音中→松开→注入）和文件转录的离线管道差异太大，强行统一污染协议 (see origin)
- **单路 AVAudioEngine 采集** — 同一路 PCM 数据同时驱动 SFSpeech 识别和 RMS 波形，避免两路音频引擎竞争硬件 (see origin)
- **模拟粘贴 (Cmd+V)** — 保存/恢复剪贴板，模拟 Cmd+V 注入文字。牺牲剪贴板短暂覆盖换取最大应用兼容性 (see origin)
- **FunASR 降级松键后离线识别** — 离线模型不适用于流式，分片识别准确率下降严重 (see origin)
- **扩展 FnKeyDetector 而非新建第二个 CGEvent tap** — 同一个 tap 回调中统一处理按键检测和事件抑制，避免两个 headInsertEventTap 的交互问题
- **SFSpeechRecognizer 用 final class 而非 actor 包装** — Swift 6 下 `resultHandler` 参数缺少 `@Sendable` 导致 actor 包装出现误报 data-race 警告。用 `OperationQueue` 控制回调线程，显式 `Task { @MainActor }` 桥接
- **SFSpeech 1 分钟限制** — 保留旧 task 的最终 partial result，无缝启动新 task，拼接输出。音频采集连续不中断
- **录音时长上限 60s** — 防止 SFSpeech 1 分钟限制和 FunASR 长音频问题。超时自动停止并注入已识别文本

---

## Output Structure

```
Sources/VoiceInput/                  # 新模块
├── AudioCaptureEngine.swift         # AVAudioEngine 管理 + RMS 计算
├── StreamingRecognizer.swift        # SFSpeechRecognizer 包装
├── VoiceInputEngine.swift           # Actor 协调器（状态机 + 注入 + 降级）
├── TextInjector.swift               # 剪贴板保存/恢复 + Cmd+V 模拟
├── VoiceInputOverlayWindow.swift    # NSPanel 悬浮窗 + 动画
├── WaveformView.swift               # RMS 驱动 5 竖条波形 (SwiftUI)
├── VoiceInputViewModel.swift        # @MainActor 桥接 + 状态绑定

Tests/VoiceInputTests/
└── VoiceInputEngineTests.swift      # Engine 状态机 + 注入 + 降级测试
```

---

## Requirements Trace

| Origin ID | Requirement | Covered by |
|-----------|-------------|------------|
| R1-R3 | 触发键监听与配置 | U2 |
| R4 | 单路 AVAudioEngine PCM 采集 | U3 |
| R5-R7 | SFSpeech 流式 + FunASR 降级 | U4, U5 |
| R8 | 剪贴板保存/恢复 Cmd+V 注入 | U5 |
| R9-R12 | NSPanel 悬浮窗结构与动画 | U6 |
| R13-R17 | RMS 波形动画 | U3, U6 |
| R18-R21 | 边缘情况（短按、超时、Escape、权限） | U5, U7 |

---

## Implementation Units

### U1. SPM Target & Infrastructure

**Goal:** 在 Package.swift 中新建 VoiceGumVoiceInput 模块，添加 Info.plist 权限声明

**Requirements:** R4, R5, R21

**Files:**
- `Package.swift` — 添加 VoiceGumVoiceInput target + product dependency
- `Resources/Info.plist` — 添加 `NSSpeechRecognitionUsageDescription`

**Approach:**
- 新建 `VoiceGumVoiceInput` Swift target，路径 `Sources/VoiceInput/`
- 依赖：`VoiceGumServices`（复用 FunASRNanoTranscriptionService、AudioConverter）、`VoiceGumFnKey`（扩展 FnKeyDetector）、`VoiceGumPreferences`
- `VoiceGum` executable 和 `VoiceGumCore` 添加 `"VoiceGumVoiceInput"` 依赖
- Info.plist 添加 `NSSpeechRecognitionUsageDescription`: `"VoiceGum needs speech recognition access for voice input transcription."`
- 已有 `NSMicrophoneUsageDescription`，无需重复

**Patterns to follow:** `VoiceGumFnKey` 目标定义（零 C 依赖的纯 Swift target）

**Test scenarios:**
- `swift build` 编译通过，VoiceGumVoiceInput 模块可被 import
- Info.plist 权限字符串在系统设置中正确显示

**Verification:** `swift build -c release` 成功，VoiceGumVoiceInput 被链接进 VoiceGum app

---

### U2. FnKeyDetector Enhancement

**Goal:** 扩展 FnKeyDetector 支持事件抑制、按键时长追踪、可配置触发键

**Requirements:** R1, R2, R3

**Files:**
- `Sources/FnKey/FnKeyDetector.swift` — 扩展回调逻辑
- `Sources/Preferences/AppPreferences.swift` — 添加 triggerKey 偏好

**Approach:**
- 现有回调返回 `Unmanaged.passRetained(event)`，改为对 Fn 键事件返回 `nil` 以抑制 emoji 选择器
- 在 keyDown 时记录 `keyDownTimestamp` (CACurrentMediaTime)，keyUp 时计算 `pressDuration`
- 通过 `Notification.Name.voiceInputTriggerKeyDown` / `.voiceInputTriggerKeyUp` 发布事件（带 duration），替代仅有的 `.fnKeyReleased`
- 添加 `AppPreferences.voiceInputTriggerKeyCode: Int`（默认 63），`FnKeyDetector` 读取此值替代硬编码
- 非 Fn 键（非触发键）事件继续返回原事件，不做抑制

**Patterns to follow:** 现有 `FnKeyDetector` 的 CGEvent tap 架构

**Test scenarios:**
- 按下 Fn 键，`voiceInputTriggerKeyDown` 通知发布，事件被抑制（emoji 选择器不出现）
- 松开 Fn 键，`voiceInputTriggerKeyUp` 通知发布，携带正确 duration
- 按下非触发键（如字母键），通知不发布，事件正常传递
- 修改 `voiceInputTriggerKeyCode` 为其他键码（如右 Option 0x3D），新键码生效

**Verification:** 启动 app 后 Fn 键不再触发 emoji 选择器，通知正确发布且携带 accurate duration

---

### U3. Audio Capture & RMS

**Goal:** AVAudioEngine 管理 + 实时 RMS 电平计算，提供原子读取接口

**Requirements:** R4, R13, R14, R15, R16

**Files:**
- `Sources/VoiceInput/AudioCaptureEngine.swift` — AVAudioEngine 生命周期 + RMS 计算

**Approach:**
- `@unchecked Sendable final class AudioCaptureEngine`（tap block 在实时音频线程，不适合 actor）
- `func start() throws` — 创建 AVAudioEngine，在 inputNode bus 0 安装 tap（bufferSize: 1024, format: nil）
- tap block 中做无分配 RMS 计算：
  ```swift
  // 遍历 floatChannelData[0]，累加平方和，除以 frameLength，开方
  var sum: Float = 0
  for i in 0..<frameLength { sum += data[i] * data[i] }
  let rms = sqrt(sum / Float(frameLength))
  ```
- `rmsLevel: Float` 通过 `os_unfair_lock` 保护的原子读写暴露，供 UI 读取
- `var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?` — 可注入回调将 buffer 喂给 SFSpeech
- `func stop()` — removeTap → engine.stop()
- 每次录音会话重建 engine（避免硬件设备切换导致的 sampleRate 不匹配崩溃）
- tap block 不做任何内存分配、锁操作或 I/O

**Patterns to follow:** 现有 `AudioConverter` 的音频格式约定（16kHz mono 基准）

**Test scenarios:**
- `start()` 成功后 `rmsLevel` 初始为 0
- 对着麦克风说话时 `rmsLevel > 0.01`
- 安静环境下 `rmsLevel` 接近 0 但 `> 0`（底噪）
- `stop()` 后 tap 移除，engine 停止，不再产生回调
- 连续 `start() → stop() → start()` 不崩溃（engine 重建）

**Execution note:** RMS 计算逻辑简单，先实现后对麦克风实测验证电平范围，再调优后续 envelope 参数。

**Verification:** 集成测试——对着麦克风说话时 rmsLevel 有明显变化，安静时接近 0

---

### U4. SFSpeech Streaming Recognizer

**Goal:** SFSpeechRecognizer 包装，处理流式转录、partial result 回调和 1 分钟限制

**Requirements:** R5, R6
**Dependencies:** U3

**Files:**
- `Sources/VoiceInput/StreamingRecognizer.swift`

**Approach:**
- `final class StreamingRecognizer`（不用 actor，规避 Swift 6 `@Sendable` bug）
- `init(locale: Locale)` — 创建 `SFSpeechRecognizer(locale:)`，设置 `recognizer.queue = OperationQueue()`（后台串行队列）
- `func start(with engine: AudioCaptureEngine) throws` — 创建 `SFSpeechAudioBufferRecognitionRequest(shouldReportPartialResults: true)`，启动 `recognitionTask`
- `var onPartialResult: ((String) -> Void)?` — 回调在 `recognizer.queue` 上，内部 `Task { @MainActor in ... }` 桥接
- `var onFinalResult: ((String) -> Void)?` — final result 回调
- `func finish()` — `request?.endAudio()` → `task?.finish()`
- `func cancel()` — `task?.cancel()`
- 1 分钟限制处理：在 `resultHandler` 中检测 state transition，当旧 task 进入 `.completed` 且非用户主动 finish 时，保存 partial result，立即创建新 request + task，拼接输出
- `static func isLanguageSupported(_ language: String) -> Bool` — 检查 `supportedLocales()` 是否包含目标 locale。`"auto"` 时用系统首选语言解析

**Patterns to follow:** 现有 `GGMLTranscriptionService` 的 `@unchecked Sendable` 模式

**Test scenarios:**
- `isLanguageSupported("zh-CN")` 返回 true（简体中文在支持列表中）
- `isLanguageSupported("ja")` 返回 false（日语不在 macOS SFSpeech 支持列表中）
- `start()` 后说话，`onPartialResult` 被多次回调，文本累积
- `finish()` 后 `onFinalResult` 被回调，文本为完整识别结果
- `cancel()` 后 `onFinalResult` 不被回调
- SFSpeech 授权 `.denied` 时 `start()` 抛出 error

**Verification:** 用 SFSpeech 支持的 locale 测试完整 start → speak → finish 流程，拿到识别文本

---

### U5. VoiceInputEngine

**Goal:** Actor 协调器——状态机、引擎调度、FunASR 降级、文本注入、焦点追踪

**Requirements:** R5, R6, R7, R8, R18, R19, R20, R21

**Dependencies:** U3, U4

**Files:**
- `Sources/VoiceInput/VoiceInputEngine.swift`
- `Sources/VoiceInput/TextInjector.swift`

**Approach:**
- `actor VoiceInputEngine` — 中心协调器
- 状态机：`idle → recording → recognizing(降级路径) → injecting → done | cancelled | error`
- `func startRecording() async`：
  1. 检查 SFSpeech 授权状态（`.notDetermined` → 请求授权；`.denied` → 标记降级路径）
  2. 检查所选语言是否在 `SFSpeechRecognizer.supportedLocales()` 中 → 决定 SFSpeech / FunASR 路径
  3. 记录 `frontmostApp = NSWorkspace.shared.frontmostApplication` 用于焦点恢复
  4. FunASR 路径：检查模型是否下载 → 未下载时标记 error(.modelNotDownloaded)
  5. 创建 `AudioCaptureEngine`，注入 `onAudioBuffer` 将 buffer 喂给 SFSpeech（SFSpeech 路径）或仅累积 PCM（FunASR 路径）
  6. SFSpeech 路径：创建 `StreamingRecognizer`，传入 `onPartialResult` 更新 overlay 文字
- `func stopRecording() async`：
  1. SFSpeech 路径：调用 `recognizer.finish()`，等待 final result
  2. FunASR 路径：将累积 PCM buffer 写入临时 WAV → 调用 `FunASRNanoTranscriptionService.transcribe(file:)` → 获取结果
  3. 将文本传给 `TextInjector.inject(text:targetApp:)`
  4. 清理临时文件
- `func cancelRecording() async` — 停止引擎，不注入，不修改剪贴板
- 60s 超时：`Task.sleep` + `stopRecording()`
- 0.3s 短按检测：keyDown 到 keyUp duration < 0.3s → cancel
- Escape 键监听：在 ViewModel 层透传
- FunASR Metal 冲突处理：调用 `FunASRNanoTranscriptionService.invalidateActiveModel()` 确保没有活跃的 Metal 上下文

**TextInjector** (`@unchecked Sendable final class`):
- `func inject(text: String, targetApp: NSRunningApplication?)`:
  1. 如果 `targetApp != NSWorkspace.shared.frontmostApplication`，先 `targetApp.activate(options: .activateIgnoringOtherApps)`
  2. 保存剪贴板所有 `NSPasteboardItem` 到数组
  3. `pasteboard.clearContents()` → `pasteboard.setString(text, forType: .string)`
  4. 通过 CGEvent 发送 Cmd+V 键序列（keyDown cmd → keyDown v → keyUp v → keyUp cmd）
  5. `DispatchQueue.main.asyncAfter(deadline: .now() + 0.15)` 恢复剪贴板
- 保存/恢复全部 pasteboardItems（不只是 string），避免丢失富文本、图片等
- 恢复失败时至少恢复 string 内容

**Patterns to follow:** 现有 `TranscriptionViewModel` 的 Task 管理 + `funasr_engine_init()` 生命周期模式

**Test scenarios:**
- SFSpeech 路径：`startRecording() → stopRecording()` 后文本注入成功
- FunASR 降级路径：日语 locale → 自动走 FunASR → 文本注入成功
- 短按 < 0.3s → `cancelRecording()`，无注入，剪贴板不变
- 60s 超时 → 自动 `stopRecording()`，已识别文本注入
- FunASR 模型未下载 → 标记 error(.modelNotDownloaded) → overlay 显示提示后消失
- 剪贴板有富文本 → 注入后恢复，原富文本内容不变
- 焦点追踪：按下 Fn 时焦点在 App A，松键前切到 App B → 文字注入 App A

**Verification:** 集成测试——按住 Fn 说一句话，文字注入目标输入框。日语场景走 FunASR 降级成功。

---

### U6. Overlay Window & Waveform

**Goal:** NSPanel 悬浮窗 + NSVisualEffectView 胶囊 + RMS 驱动波形动画

**Requirements:** R9, R10, R11, R12, R13, R14, R15, R16, R17

**Dependencies:** U3 (AudioCaptureEngine 提供 rmsLevel)

**Files:**
- `Sources/VoiceInput/VoiceInputOverlayWindow.swift`
- `Sources/VoiceInput/WaveformView.swift`

**Approach:**

**VoiceInputOverlayWindow:**
- `final class VoiceInputOverlayWindow: NSPanel`
- 初始化：`styleMask: [.borderless, .nonActivatingPanel]`，`backing: .buffered`
- `level = .floating`（或 `.mainMenu` 确保全屏应用上显示）
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`
- `contentView` 设置为 `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)`
- NSVisualEffectView 设置 `wantsLayer = true`, `layer?.cornerRadius = 28`, `layer?.masksToBounds = true`
- 窗口尺寸：高度固定 56px，宽度弹性（最小 ~240px，最大 ~620px）
- `positionAtScreenBottom()`：使用 `NSScreen.main?.visibleFrame` 计算底部居中位置
- `animateIn()`：设置初始 alpha=0 + y 偏移 -30，`NSAnimationContext.runAnimationGroup(duration: 0.35, timingFunction: .easeOut)` → alpha=1 + y+30
- `animateOut(completion:)`：`NSAnimationContext.runAnimationGroup(duration: 0.22, timingFunction: .easeIn)` → alpha=0 + scale 0.8
- 内容布局：左侧 `WaveformView`（44×32px）+ 右侧 `NSTextField`（弹性宽度 160-560px）
- 文字宽度变化 0.25s 动画过渡
- 不支持拖拽移动（`isMovable = false`）

**WaveformView:**
- SwiftUI `NSViewRepresentable` 或纯 AppKit `NSView`
- 5 根竖条，每根宽度 4px，间距 4px，总宽度 44px，高度范围 4-32px
- 权重：[0.5, 0.8, 1.0, 0.75, 0.55] 乘到当前 RMS 值
- Envelope 平滑：维护每根 bar 的 `currentHeight`，每帧 `currentHeight = attack ? max(currentHeight, target) : currentHeight + (target - currentHeight) * release`
- 随机抖动：每帧对 target 施加 `Float.random(in: -0.04...0.04) * target`
- 使用 `CADisplayLink` 驱动 60fps 更新（非 TimelineView）
- 安静时竖条保持最小高度 2px（非零基线）

**Patterns to follow:** 现有 `AppDelegate` 的 NSWindow 创建模式

**Test scenarios:**
- 窗口弹入：spring 动画流畅，终点位置正确（屏幕底部居中）
- 窗口退场：scale 动画流畅，完毕后 `orderOut` 生效
- 波形响应 RMS：对着麦克风说话时竖条高度明显变化，安静时降至最小 2px
- 权重效果：中间竖条（权重 1.0）最高，两侧递减
- Envelope：突然大声说话时竖条快速上升（attack 40%），安静后缓慢下降（release 15%）
- 暗色/亮色模式切换：.hudWindow 材质自动适配
- 多显示器：窗口出现在活跃屏幕底部居中

**Execution note:** CADisplayLink 在实现时优先；如果实测发现与 SwiftUI 更新周期冲突导致卡顿，可降级到 TimelineView。Envelope 参数（attack 40%、release 15%）为初值，需对麦克风实测后微调。

**Verification:** 手动测试——按住 Fn 说话，观察波形是否自然响应声音大小，悬浮窗位置和动画是否正确

---

### U7. VoiceInputViewModel

**Goal:** @MainActor 桥接层，连接 VoiceInputEngine 和 overlay UI

**Requirements:** R20 (Escape 取消)

**Dependencies:** U5, U6

**Files:**
- `Sources/VoiceInput/VoiceInputViewModel.swift`

**Approach:**
- `@MainActor final class VoiceInputViewModel: ObservableObject`
- `@Published var overlayState: OverlayState = .hidden`
- `@Published var partialText: String = ""`
- `@Published var rmsLevel: Float = 0`
- `@Published var statusText: String = ""` — "录音中" / "识别中" / "准备中..."
- `private let engine = VoiceInputEngine()`
- `func handleTriggerKeyDown()` → `await engine.startRecording()`
- `func handleTriggerKeyUp()` → `await engine.stopRecording()`
- `func handleEscape()` → `await engine.cancelRecording()`
- 监听 `VoiceInputEngine` 状态变化更新 `overlayState`
- 在 `startRecording()` 后启动 CADisplayLink/Timer 轮询 `AudioCaptureEngine.rmsLevel` 更新 `rmsLevel`
- `OverlayState` enum: `hidden`, `showing`, `recognizing`, `error(String)`

**Patterns to follow:** 现有 `TranscriptionViewModel` 的 `@MainActor ObservableObject` + `@Published` 模式

**Test scenarios:**
- `handleTriggerKeyDown()` → `overlayState` 变为 `.showing`
- SFSpeech 路径 `handleTriggerKeyUp()` → `overlayState` 变为 `.hidden`，`partialText` 被清空
- `handleEscape()` → `overlayState` 变为 `.hidden`，无文字注入
- FunASR 路径 → `overlayState` 经过 `.showing → .recognizing → .hidden`
- 模型未下载 → `overlayState` 变为 `.error("离线模型未下载")`

**Verification:** 集成测试——按住 Fn → overlay 显示 → 波形动画 → 文字更新 → 松键 → overlay 消失 → 文字注入

---

### U8. Settings & App Integration

**Goal:** 偏好设置 UI、AppDelegate 启动集成、权限协调

**Requirements:** R3, R21

**Dependencies:** U1, U2, U7

**Files:**
- `Sources/Preferences/AppPreferences.swift` — 添加 voice input 相关键
- `Sources/Core/SettingsView.swift` — 添加语音输入设置区域
- `Sources/App/AppDelegate.swift` — 启动 FnKeyDetector、初始化 VoiceInputViewModel

**Approach:**
- AppPreferences 新键：
  - `voicegum.voiceInput.triggerKeyCode`（Int，默认 63）
  - `voicegum.voiceInput.enabled`（Bool，默认 true）
  - 遵循现有 `voicegum.` 前缀、dot-separated 命名惯例
- SettingsView：在 General tab 添加"语音输入" section，包含触发键选择器（Picker 列出可用键位：Fn、右 Option、右 Command）和启用开关
- AppDelegate: `applicationDidFinishLaunching` 中调用 `FnKeyDetector.shared.start()` 和 `VoiceInputViewModel.shared.activate()`
- 权限协调：
  - 麦克风权限：已有 `NSMicrophoneUsageDescription`，AVAudioEngine 启动时系统弹窗
  - SFSpeech 权限：VoiceInputEngine 首次 start 时调用 `SFSpeechRecognizer.requestAuthorization`
  - 辅助功能权限：CGEvent tap 创建失败时（返回 nil），在 overlay 中显示引导文本"请在系统设置 → 隐私与安全性 → 辅助功能中授权 VoiceGum"
- `applicationWillTerminate` 中调用 `VoiceInputEngine.cleanup()` 取消正在进行的录音

**Patterns to follow:** 现有 `AppPreferences.Keys` 命名约定 + SettingsView Picker/Toggle 模式

**Test scenarios:**
- 首次启动 → FnKeyDetector 启动 → 按下 Fn 不触发 emoji 选择器
- 在设置中切换触发键为右 Option → 新键生效
- 关闭"启用语音输入" → 按 Fn 无反应
- 拒绝麦克风权限 → Engine 启动失败 → overlay 显示错误提示
- `_exit(0)` 前 cleanup → 录音 session 正确结束

**Verification:** 完整流程手动测试——设置页可切换触发键；启动后 Fn 键抑制生效

---

## System-Wide Impact

- **CGEvent tap** — 扩展现有 FnKeyDetector，新增全局事件抑制（Fn 键不再触发 emoji 选择器）。影响所有用户
- **辅助功能权限** — 现有权限已要求（FnKeyDetector 需要），功能路径不变
- **SFSpeechRecognizer 网络请求** — 新增网络依赖（Apple SFSpeech 服务器），仅录音时使用
- **剪贴板** — 注入期间短暂修改 `NSPasteboard.general`，150ms 后恢复
- **Metal 资源** — FunASR 降级路径调用 `invalidateActiveModel()` 确保单 Metal 后端；与其他 ASR 任务的协调通过现有 `activeInstance` 机制
- **应用激活策略** — 焦点追踪可能调用 `NSRunningApplication.activate()` 恢复原应用焦点

---

## Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| SFSpeech 1 分钟限制导致 text 丢失 | 中 | 保留 partial result，无缝重启 task，拼接输出 |
| 剪贴板恢复竞态条件（150ms 不足） | 高 | 实测多种应用验证延迟；必要时加入 `NSWorkspace.didActivateApplicationNotification` 确认粘贴完成 |
| CGEvent Cmd+V 被安全软件拦截 | 低 | 非沙盒应用，Accessibility 权限已涵盖 |
| Fn 键在外接键盘上 keyCode 不同 | 中 | 可配置触发键 + 日志记录未知 keyCode 供排查 |
| FunASR Metal 与现有 ASR 冲突 | 高 | `invalidateActiveModel()` + `waitForTranscriptionCompletion(timeout:)` 确保无并发 Metal 上下文 |
| macOS 新版本 CGEvent tap 行为变化 | 低 | FnKeyDetector 原有风险；VoiceInput 模块可独立禁用 |
| 麦克风硬件切换导致 engine 崩溃 | 中 | 每次录音会话重建 engine（U3）；崩溃被 catch，elevate 到 error 状态 |

---

## Scope Boundaries

### Deferred for later

- 持续听写模式（toggle on/off，无需按住键）
- 语音指令 / 关键词唤醒
- 音频输入设备选择 UI
- 多语言自动检测
- 锁屏/登录界面语音输入
- 语音输入结果保存到历史记录

### Deferred to Follow-Up Work

- FnKeyDetector 多触发键支持（当前仅单一可配置键）
- FunASR-Nano 流式增量识别（需 C FFI 改造，规划复杂度高）

---

## Dependencies / Assumptions

- macOS 14+ 运行环境，SFSpeechRecognizer 可用
- 辅助功能权限已由现有 FnKeyDetector 触发，用户已授权或将被提示
- `FunASRNanoTranscriptionService` 可处理 < 60s 的短音频，无需修改
- SFSpeechRecognizer 不支持的语言列表以 `SFSpeechRecognizer.supportedLocales()` 为准（非硬编码）
- 系统默认麦克风采样率 ≥ 16kHz
- 非沙盒分发（与现有 Hardened Runtime + `_exit(0)` 模式一致）

---

## Deferred Implementation Notes

- AVAudioEngine tap buffer size 为初值 1024，需实测调优（CPU vs 波形延迟权衡）
- Envelope 参数（attack 40%、release 15%）为初值，需对麦克风实测微调
- 剪贴板恢复的 150ms 延迟为经验值，需对微信/Chrome/Terminal 等目标应用验证
- CADisplayLink vs TimelineView 的取舍依赖实测帧率——CADisplayLink 优先
- SFSpeech 1 分钟限制的实际触发边界待实测确认（Apple 文档模糊，可能在 50-70s 范围内）
- Fn 键外部键盘 keyCode 映射需实测验证（可能有固件级差异）

---

## Outstanding Questions

### Resolved

- SFSpeech 离线时静默降级（决议：静默降级，与语言不支持行为一致）
- 焦点切换时的粘贴目标（决议：追踪原始焦点，粘贴前恢复）
- 模型未下载 UX（决议：悬浮窗短暂提示后消失）

### Deferred to Implementation

- Fn 键在外接键盘上的 keyCode 映射（实测验证）
- Envelope 参数最终值（实测调优）
- 剪贴板恢复延迟在不同应用中的最佳值（应用兼容性测试）
