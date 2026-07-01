---
date: 2026-06-29
topic: hold-to-talk-voice-input
---

# Hold-to-Talk Voice Input

## Summary

按住说话（Hold-to-Talk）语音输入：按住可配置触发键录音，松开后通过模拟粘贴将转录文字注入当前焦点输入框。优先使用 Apple SFSpeechRecognizer 流式转录，语言不支持时降级到 FunASR-Nano 松键后离线识别。录音时屏幕底部居中显示胶囊状悬浮窗，包含实时音频 RMS 波形和流式转录文本。

---

## Problem Frame

VoiceGum 目前仅支持文件级离线转录：用户需要先录音保存文件，再拖入应用等待识别。这个流程在即时通讯、文档编辑等场景中严重打断心流——用户本想说一句话直接出现在输入框里，实际却要经历"打开录音工具→录音→保存→拖入 VoiceGum→等待识别→复制→切回应用→粘贴"八个步骤。

macOS 自带的听写功能（双击 Fn 触发）体验粗糙、语言受限、且无法自定义引擎。VoiceGum 已有的 FunASR 离线引擎（SenseVoice / FunASR-Nano）和本地模型管理能力为自建语音输入提供了基础设施，缺的只是实时采集、流式识别和注入管道的组合。

本功能将语音输入压缩为"按住→说话→松开"一个动作，识别结果直接出现在正在编辑的位置。

---

## Actors

- A1. **用户**：按下触发键开始说话，期望转录文字出现在当前焦点的输入框中
- A2. **目标应用**：前台应用中拥有键盘焦点的文本输入控件（浏览器输入框、代码编辑器、聊天窗口等）
- A3. **macOS 系统**：权限守门人——辅助功能权限（CGEvent tap）和麦克风权限（AVAudioEngine）

---

## Key Flows

- F1. **SFSpeech 流式识别（主路径）**
  - **Trigger:** 用户按住触发键
  - **Actors:** A1, A2, A3
  - **Steps:** 按键 → 悬浮窗弹入（弹簧动画 0.35s）→ 用户说话 → 波形随声音跳动，流式文本实时更新 → 松开按键 → 文本通过模拟粘贴注入焦点输入框 → 悬浮窗缩放退场（0.22s）
  - **Outcome:** 转录文字出现在目标输入框光标位置
  - **Covered by:** R1, R2, R4, R6, R7, R8

- F2. **FunASR 离线降级**
  - **Trigger:** 用户按住触发键，SFSpeech 不支持当前语言
  - **Actors:** A1, A2
  - **Steps:** 按键 → 悬浮窗弹入，波形动画运行但无流式文本（显示"录音中"指示）→ 用户说话 → 松开按键 → 保存临时 WAV → 调用 FunASR-Nano → 悬浮窗显示识别中状态 → 结果返回 → 文本注入 → 悬浮窗退场
  - **Outcome:** 转录文字出现在目标输入框光标位置，延迟增加 1-3 秒
  - **Covered by:** R1, R3, R4, R5

- F3. **取消录音**
  - **Trigger:** 用户短按（< 0.3s）或按 Escape
  - **Actors:** A1
  - **Steps:** 触发取消条件 → 悬浮窗退场 → 无文字注入 → 剪贴板不受影响
  - **Outcome:** 无任何副作用
  - **Covered by:** R9, R10

---

## Requirements

**触发键与全局监听**
- R1. 按住可配置触发键（默认物理 Fn 键，keyCode 63）开始录音，松开停止并触发注入
- R2. 使用 CGEvent tap (headInsertEventTap) 全局监听按键；Fn 键事件必须被抑制（回调返回 nil），防止触发系统 emoji 选择器
- R3. 触发键可在偏好设置中变更，存储于 UserDefaults

**音频采集**
- R4. 使用 AVAudioEngine 单路采集系统默认麦克风，格式为 mono 16kHz PCM；同一路 PCM 数据同时用于 RMS 波形计算和 SFSpeech 识别请求

**转录引擎**
- R5. 优先使用 SFSpeechRecognizer 流式转录；实时识别结果逐片更新悬浮窗文字
- R6. 当 SFSpeech 不支持所选语言，或授权被拒，或设备离线导致 SFSpeech 不可用时，静默降级到 FunASR-Nano：录音完整片段，松键后保存临时 WAV 并调用离线识别。降级对用户透明，不弹错误提示
- R7. 降级路径直接复用现有 `FunASRNanoTranscriptionService.transcribe(file:)` 接口，无需新增离线识别逻辑

**文本注入**
- R8. 注入前保存当前剪贴板内容，通过 CGEvent 模拟 Cmd+V 粘贴，粘贴后恢复原始剪贴板内容

**悬浮窗**
- R9. 录音时在屏幕底部居中显示胶囊状悬浮窗：NSPanel (nonActivatingPanel)，NSVisualEffectView (.hudWindow 材质)，无 titlebar 和红绿灯，56px 高度，28px 圆角半径
- R10. 窗口弹性宽度：最小约 240px（波形 + 最小文字区），最大约 620px（波形 + 560px 文字区）；宽度随文字增长平滑过渡（0.25s）
- R11. 入场动画：弹簧动画 0.35s；退场动画：缩放动画 0.22s
- R12. 悬浮窗不抢夺键盘焦点（nonActivatingPanel）

**波形动画**
- R13. 左侧 5 根竖条波形（44×32px 区域），竖条高度由实时音频 RMS 电平驱动
- R14. 五根竖条权重 [0.5, 0.8, 1.0, 0.75, 0.55]，形成中间高两侧低的自然频谱感
- R15. 对 RMS 值施加平滑包络：attack 40%，release 15%
- R16. 每帧对每根竖条施加 ±4% 随机抖动，增强有机感
- R17. 波形区域整体清晰可见——安静时竖条保持最小可见高度（非零基线），说话时明显跳动

**边缘情况与错误处理**
- R18. 按键时长 < 0.3s 视为误触，不注入文字
- R19. 录音最长 60s，超时自动停止并注入已识别文本
- R20. 录音期间按 Escape 取消，不注入文字，不修改剪贴板
- R21. SFSpeech 授权被拒或不可用时，静默降级到 FunASR-Nano；麦克风权限被拒时，引导用户开启系统权限

---

## Acceptance Examples

- AE1. **Covers R1, R5, R11, R13.** 用户按住 Fn 键在微信输入框中说话，悬浮窗从屏幕底部弹入（弹簧动画），波形随说话跳变，流式文字逐词出现。松键后文字粘贴到微信输入框，悬浮窗缩放退场。整个过程焦点从未离开微信。

- AE2. **Covers R6, R7.** 用户选择日语作为识别语言（SFSpeech 不支持），按住 Fn 说话。悬浮窗显示波形和"录音中"提示。松键后悬浮窗显示"识别中"，1-3 秒后结果粘贴到焦点输入框。

- AE3. **Covers R18.** 用户不小心碰到 Fn 键立即松开（< 0.3s），悬浮窗短暂出现后消失，无文字注入，剪贴板不变。

- AE4. **Covers R20.** 用户按住 Fn 说了半句，发现说错了，按 Escape。录音取消，悬浮窗退场，无文字注入。

- AE5. **Covers R8.** 用户剪贴板中有重要内容。按住 Fn 说完话松键后，转录文字正确粘贴，原剪贴板内容被恢复，再次 Cmd+V 粘贴的仍是原始内容。

- AE6. **Covers R19.** 用户按住 Fn 说了超过 60 秒，系统自动停止录音并将已识别的文字注入输入框。

---

## Success Criteria

- 用户从按下触发键到文字出现在输入框，SFSpeech 路径端到端延迟 < 1s（不含网络波动）
- 波形动画以 60fps 平滑运行，无可见卡顿或跳帧
- 剪贴板恢复成功率 100%——用户无法感知剪贴板曾被修改
- 悬浮窗在所有支持暗色/亮色模式的屏幕上正确渲染（.hudWindow 材质自适应）
- FunASR 降级路径端到端延迟 < 5s（含录音 + 保存 + 离线识别）

---

## Scope Boundaries

- 不包含持续听写模式（切换开关后无需按住键持续录音）
- 不包含语音指令或关键词唤醒（如 "Hey VoiceGum"）
- 不包含音频输入设备选择 UI（使用系统默认麦克风）
- 不包含多语言自动检测（用户需手动切换识别语言）
- 语音输入仅在应用层触发，不包含锁屏或登录界面使用场景

---

## Key Decisions

- **独立 VoiceGumVoiceInput 模块而非扩展 TranscriptionService 协议**：语音输入的状态机（按下→录音中→松开→注入）和文件转录的离线管道差异太大，强行统一会污染协议和所有现有实现
- **单路 AVAudioEngine 采集而非 SFSpeech 内置引擎 + 独立波形采集**：同一路 PCM 同时驱动波形和识别，避免两路音频引擎竞争硬件、波形与识别数据源不一致
- **模拟粘贴 (Cmd+V) 而非 Accessibility 直接注入**：牺牲剪贴板短暂覆盖，换取几乎所有应用（Electron、Terminal、原生 App）的兼容性
- **FunASR 降级走松键后离线识别而非分片流式**：离线模型不是为流式设计的，分片识别准确率下降严重，松键后 1-3 秒延迟可接受

---

## Dependencies / Assumptions

- SFSpeechRecognizer 在 macOS 14+ 上可用，需要网络连接（Apple 服务器）
- 辅助功能权限已由现有 FnKeyDetector 触发系统弹窗，本功能复用同一 CGEvent tap
- 现有 `FunASRNanoTranscriptionService` 可处理短音频片段（< 60s），无需修改
- 系统默认麦克风采样率至少 16kHz
- 触发键配置可能需处理与系统快捷键冲突（Fn 键无法被系统偏好设置中的快捷键占用，相对安全）

---

## Outstanding Questions

### Deferred to Planning

- [Affects R2][Technical] Fn 键在某些外接键盘上 keyCode 可能不是 63——需验证并通过 CGEvent 的 keyCode 映射处理
- [Affects R4][Technical] AVAudioEngine tap 的 buffer 大小需要实测调优——过小浪费 CPU，过大增加波形延迟
- [Affects R13][Technical] 波形动画使用 CADisplayLink vs SwiftUI TimelineView 的取舍，依赖实测帧率
- [Affects R8][Technical] 剪贴板恢复的竞态条件——粘贴事件和恢复事件之间的时序需验证
