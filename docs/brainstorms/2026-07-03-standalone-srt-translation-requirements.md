---
date: 2026-07-03
topic: standalone-srt-translation
---

# 独立字幕文件翻译

## Summary

在菜单栏增加"翻译字幕文件…"功能：用户选择一个已有 SRT 文件，应用复用已配置的 LLM 将其翻译为目标语言，生成 `{原文件名}_{时间戳}.{语言代码}.srt` 并存放在原文件同目录。整个流程不依赖转录管道，独立运作。

---

## Problem Frame

当前 VoiceGum 的翻译能力（`LLMClient.translate()`、`SubtitleFormatter`、翻译偏好设置）仅在转录完成后自动触发。用户如果已有 SRT 字幕文件（来自其他工具、历史导出、或他人分享），想用 VoiceGum 的 LLM 翻译能力处理时，必须先导入音频重新转录——这在只有字幕文件没有音频时无法操作。

已有翻译基础设施（LLM 调用、字幕格式化、偏好设置）可以直接复用，缺失的只有两个环节：SRT 文件的读取解析、以及一个独立于转录管道的触发入口。

---

## Actors

- A1. **用户**: 有 SRT 字幕文件需要翻译，通过菜单触发流程
- A2. **LLM 服务**: 接收翻译请求并返回翻译结果

---

## Key Flows

- F1. **独立 SRT 翻译**
  - **Trigger:** 用户在菜单栏选择"翻译字幕文件…"（Cmd+Shift+T）
  - **Actors:** A1, A2
  - **Steps:** 菜单点击 → NSOpenPanel 选择 .srt 文件 → 解析 SRT 为字幕片段 → 按现有翻译偏好调用 `LLMClient.translate()` → 按现有输出偏好调用 `SubtitleFormatter` 生成译文 SRT → 写入同目录 → 显示完成提示
  - **Outcome:** 译文 SRT 文件出现在原文件同目录，名称格式为 `{原文件名}_{时间戳}.{语言代码}.srt`
  - **Covered by:** R1, R2, R3, R4, R5, R6, R7, R8

- F2. **翻译失败处理**
  - **Trigger:** 翻译过程中 LLM 返回错误或解析失败
  - **Actors:** A1
  - **Steps:** 错误发生 → 显示错误提示（含错误原因）→ 不产生残缺的输出文件
  - **Outcome:** 用户看到明确的错误信息，无垃圾文件残留
  - **Covered by:** R9, R10

---

## Requirements

**菜单入口**
- R1. 菜单栏新增"翻译字幕文件…"项，快捷键 Cmd+Shift+T
- R2. 菜单项始终可用（不依赖当前是否有转录任务）

**文件选择**
- R3. 点击菜单项弹出 NSOpenPanel，过滤 `.srt` 文件（也接受 `.txt` 等纯文本）
- R4. 仅支持单选，单次只翻译一个文件

**SRT 解析**
- R5. 解析标准 SRT 格式：序号、时间码（`HH:MM:SS,mmm --> HH:MM:SS,mmm`）、单行或多行文本
- R6. 解析结果映射为 `[SubtitleSegment]`，保留 startMs / endMs / text
- R7. 对格式不兼容的文件显示明确错误提示

**翻译执行**
- R8. 复用 `LLMClient.translate()` 执行翻译，复用现有翻译偏好（目标语言、翻译模式 batch/per-segment、输出模式 bilingual/translation-only、自定义提示词）
- R9. 复用 `SubtitleFormatter.toSRT()` / `toSRTBilingual()` 生成译文 SRT

**输出文件**
- R10. 输出文件名格式：`{原文件名}_{时间戳}.{目标语言代码}.srt`，时间戳格式为 `YYYYMMDD-HHmmss`
- R11. 输出文件默认放在原文件所在目录
- R12. 如输出文件已存在，覆盖（不弹确认对话框，与简单直接的设计保持一致）

**进度与反馈**
- R13. 翻译过程中显示进度窗口：当前进度（X/N 段）和可取消按钮
- R14. 翻译完成后弹窗提示"翻译完成"，含输出文件路径
- R15. 进度窗口支持取消：点击取消后停止剩余 LLM 调用，不生成输出文件

**错误处理**
- R16. LLM 未配置时弹窗提示"请先在设置中配置 LLM"
- R17. LLM 调用失败时弹窗提示具体错误信息，不产生残缺输出文件
- R18. SRT 文件为空（0 条字幕）时弹窗提示"文件中未找到有效字幕"

---

## Acceptance Examples

- AE1. **Covers R1, R3, R5, R6, R10, R11.** 用户按 Cmd+Shift+T，选择一个 `movie.srt`（含 50 条字幕），目标语言设为 zh-CN。进度窗口显示"正在翻译… 1/50"逐步到"50/50"。完成后同目录生成 `movie_20260703-143052.zh-CN.srt`，内容为翻译后的有效 SRT。
- AE2. **Covers R8, R9.** 用户输出模式设为双语，翻译后生成的文件每条字幕块为「原文\n译文」格式。
- AE3. **Covers R8.** 用户翻译模式设为整批，50 条字幕合并为一次 LLM 请求，返回后解析回 50 条保留原时间轴。
- AE4. **Covers R16.** 用户未配置 LLM API key，点击菜单项 → 选择 SRT 文件 → 弹窗"请先在设置中配置 LLM"，不发起翻译。
- AE5. **Covers R7.** 用户选择一个非 SRT 格式的二进制文件 → 弹窗"无法解析该文件，请确认其为有效的 SRT 字幕文件"。
- AE6. **Covers R15.** 翻译进行到 20/100 段时用户点击取消 → 停止剩余调用，不生成输出文件，进度窗口关闭。
- AE7. **Covers R18.** 用户选择一个只有空行的 .srt 文件 → 弹窗"文件中未找到有效字幕"。
- AE8. **Covers R12.** 目标文件已存在时直接覆盖，不弹确认框。

---

## Success Criteria

- 用户有一个 SRT 文件 → 菜单选择 → 等待翻译 → 同目录得到译文 SRT，无需离开应用
- 翻译结果与转录后自动翻译的质量一致（共用同一 LLM 调用路径和提示词）
- 大文件（200+ 段）翻译可取消，不会阻塞应用

---

## Scope Boundaries

- 不涉及 SRT 预览/编辑界面
- 不涉及多文件批量翻译
- 不涉及非 SRT 格式（ASS、VTT 等）的解析
- 不支持翻译结果回写历史记录（HistoryManager）
- CLI 不支持此功能（后续可加）
- 不与现有转录→翻译管道耦合，独立运作

---

## Key Decisions

- 复用现有翻译偏好而非独立配置：减少设置页改动，翻译参数（目标语言、模式、提示词）保持一致
- 进度窗口使用简单 floating panel 而非内嵌到主窗口：独立翻译与主窗口转录任务无关，独立窗口更清晰
- 不导入历史记录：保持功能简单，用户需要的是文件→翻译→文件，不需要持久化中间状态

---

## Dependencies / Assumptions

- 依赖 `LLMClient.translate()` 方法及其所有 provider 支持
- 依赖 `SubtitleFormatter.toSRT()` / `toSRTBilingual()` 的现有输出逻辑
- 依赖 `AppPreferences` 中的翻译相关偏好（`translateTargetLanguage`、`translateMode`、`translateOutputMode`、`translatePrompt`）
- 假设输入的 SRT 文件使用 UTF-8 编码
- 假设标准 SRT 格式（序号/时间码/文本），不处理非标准变体
