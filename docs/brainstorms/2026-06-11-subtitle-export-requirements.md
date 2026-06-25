---
date: 2026-06-11
topic: subtitle-export
---

# 字幕导出

## Summary

转写完成后自动生成 SRT 字幕文件，同时支持从历史记录手动导出。利用 SenseVoice 引擎 VAD 的语音段时序数据，按 VAD 语音段粒度切分时间轴。

---

## Problem Frame

VoiceGum 目前已能完成音频/视频的语音转文字，但输出只有纯文本。用户拿到转写结果后，如果需要字幕（导入剪辑软件、上传视频平台、本地播放器加载），必须手动将文本切成段落并逐一标注时间码——这恰好是 ASR 引擎在转写过程中已经计算出的信息，只是被丢弃了。

SenseVoice 的 VAD 模块在转写前已精确检测出每个语音段的起止时间（`t0`/`t1`），当前 C API 将这些分段拼接为单一文本后仅返回拼接结果。暴露并利用这份已有的时序数据，在转写完成时自动输出字幕文件，是成本最低、价值最直接的字幕方案。

---

## Key Flows

- F1. 自动生成字幕
  - **Trigger:** 转写流程进入 `completed` 状态
  - **Actors:** 系统
  - **Steps:**
    1. 转写完成，获得文本和分段时序数据
    2. 将分段数据格式化为 SRT
    3. 写入结果目录，文件名基于源文件名（如 `meeting.srt`）
    4. 将分段时序数据存入 HistoryEntry
  - **Outcome:** 结果目录中同时存在转写文本和 SRT 字幕文件
  - **Failure:** 如果 VAD 未检测到任何语音段（静音/噪音音频），跳过 SRT 生成，不创建空文件
  - **Covered by:** R1, R2, R3, R5, R7, R8

- F2. 手动导出字幕
  - **Trigger:** 用户在历史记录界面选择一条记录，点击导出字幕
  - **Actors:** 用户
  - **Steps:**
    1. 用户打开历史记录，选中目标条目
    2. 点击导出按钮，选择"导出字幕"
    3. 系统从 HistoryEntry 读取分段时序数据，格式化为 SRT
    4. 弹出保存面板（`NSSavePanel`），用户选择保存位置
    5. 写入文件
  - **Outcome:** 用户在选定位置获得 SRT 文件
  - **Failure:** 如果历史记录中无时序数据（旧数据），显示提示"此记录不含时序数据，无法生成字幕"；用户取消保存面板无副作用关闭；写入失败（目录不可写、磁盘满）显示系统错误提示
  - **Covered by:** R4, R5, R6, R7, R8

---

## Requirements

**时序数据获取**
- R1. C API 扩展：新增分段数据结构（起止时间 + 文本），增加分段输出能力，不改变现有纯文本返回路径（具体 API 方案待规划确定）
- R2. Swift 层 `TranscriptionResult` 新增可选 `segments` 字段，承载分段时序数据

**自动生成**
- R3. 转写成功完成后，自动在结果目录生成 `.srt` 文件，文件名基于源文件名（如 `meeting.srt`）。重复转写同一源文件时追加时间戳后缀避免覆盖（如 `meeting_20260611T143021.srt`）

**手动导出**
- R4. 历史记录详情/列表页新增"导出字幕"操作，触发 `NSSavePanel` 保存 SRT 文件
- R5. `HistoryEntry` 新增可选 `segments` 字段，持久化分段时序数据，确保手动导出使用精确时序而非事后估算
- R6. 对不含时序数据的旧历史记录，导出按钮置灰或点击后提示不可用
- R9. `segments` 字段需保证向后兼容：旧版应用打开含 `segments` 的新历史记录时，静默忽略未知字段，不崩溃不丢数据

**SRT 格式化**
- R7. SRT 格式严格遵循标准：序号从 1 递增、时间码 `HH:MM:SS,mmm --> HH:MM:SS,mmm`、UTF-8 编码、段落间空行分隔
- R8. 极短分段（<0.3秒）与相邻分段合并，避免闪烁字幕
- R10. 超长分段（>7秒或>84字符）在标点或合理断点处拆分为多条字幕条目，保证每条字幕可读

---

## Acceptance Examples

- AE1. **Covers R3, R7.** 转写 30 秒音频，VAD 检测到 3 个语音段。转写完成后结果目录生成 `audio.srt`，包含 3 条字幕条目，时间码递增无重叠，UTF-8 无乱码。
- AE2. **Covers R4, R5.** 用户从历史记录中选择一条含时序数据的记录，点击导出字幕，选择桌面路径保存。生成的 SRT 时间码与自动生成的一致。
- AE3. **Covers R6.** 用户选择一条旧版历史记录（升级前产生，无 `segments` 数据），"导出字幕"按钮不可用。

---

## Success Criteria

- 用户在转写完成后无需任何额外操作即可获得可用的 SRT 字幕文件
- 生成的 SRT 文件可在 VLC、IINA、QuickTime（配合第三方插件）中正常加载，音画同步
- 从历史记录导出的字幕与转写完成时自动生成的字幕时间码一致
- 旧版历史记录不会因新增字段而崩溃或丢失数据

---

## Scope Boundaries

- VTT、ASS 等其他字幕格式
- 词级别时间戳
- 字幕预览/编辑 UI
- 基于 refined/summary 文本生成字幕（仅支持 rawText）
- 批量导出多条记录

---

## Key Decisions

- **SRT only**: 通用性最高，实现复杂度最低，所有主流播放器和剪辑软件原生支持。VTT 可在后续版本添加
- **VAD 分段粒度**: 引擎原生支持，不需引入 CTC 强制对齐。设计上预留 `segments` 结构扩展空间，后续若支持词级时间戳可无缝升级
- **时序数据持久化到 HistoryEntry**: 确保手动导出使用精确时序，避免事后估算的质量下降。代价是历史记录文件体积增大，但分段数据量远小于音频本身

---

## Dependencies / Assumptions

- SenseVoice ggml 实现的 VAD 分段（`silero-vad`）已稳定输出 `t0`/`t1`，不需更换 VAD 模型
- 假设结果目录可写，SRT 文件体积远小于音频文件，不构成存储压力

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1][Technical] C API 扩展的具体方案：新增独立函数 `sv_transcribe_with_segments` 还是修改现有函数返回 JSON
- [Affects R5][Technical] `segments` 字段的持久化格式（JSON 数组嵌入 HistoryEntry，还是独立文件）
- [Affects R8][Needs research] 极短分段的合并阈值（0.3秒）是否需要根据语言调整
