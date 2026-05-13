---
title: Separate LLM System Prompts from Provider Configuration
type: refactor
status: completed
date: 2026-05-13
---

# Separate LLM System Prompts from Provider Configuration

## Overview

将 LLM 的 System Prompt 从 Provider 配置中解耦，改为按**任务类型**（Refine / Summary）独立存储。两个任务共享同一套 LLM Provider 配置（baseURL / model / API key），但使用各自独立的 System Prompt。

## Problem Statement

当前 System Prompt 通过 `voicegum.llm.{provider}.prompt` 按 Provider 存储，一个 Provider 只能有一个 Prompt。但用户有两个 LLM 使用场景：

1. **Refine** — 润色转写后的文字
2. **Summary** — 生成全文摘要

两个场景需要的 System Prompt 完全不同，不应该绑定到 Provider。

## Proposed Solution

Provider 配置保持不变，Prompt 从 Provider 键空间移出，改为按任务类型存储：

```
# Provider 配置（不变）
voicegum.llm.{provider}.baseURL
voicegum.llm.{provider}.model
voicegum.llm.{provider}.apiKey

# 任务 Prompt（新增，Provider 无关）
voicegum.llm.refinePrompt
voicegum.llm.summaryPrompt
```

## Technical Approach

### Data Model Changes (`AppPreferences.swift`)

**移除：**
- `llmPrompt(for:)` 方法
- `setLLMPrompt(_:for:)` 方法

**新增：**
- `refinePrompt` / `setRefinePrompt(_:)` — Refine 任务的 System Prompt，带默认值
- `summaryPrompt` / `setSummaryPrompt(_:)` — Summary 任务的 System Prompt，带默认值

默认 Refine Prompt：
> You are a text refinement assistant. Improve the following transcribed speech for readability while preserving the meaning. Fix any transcription errors, add proper punctuation, and format appropriately.

默认 Summary Prompt：
> You are a text summarization assistant. Create a concise summary of the following transcribed text. Capture the key points and main ideas while keeping the summary brief and well-structured.

### UI Changes (`SettingsView.swift`)

LLM 设置 Tab 重组为两个独立区域：

1. **API 配置**（现有，移除 Prompt 编辑器）— Provider / Base URL / Model / API Key / Test
2. **任务提示词**（新增 Section）— Refine Prompt TextEditor + Summary Prompt TextEditor，各自带默认值

### LLMClient Changes (`LLMClient.swift`)

- `refine(text:customPrompt:)` 保持不变
- 新增 `summarize(text:customPrompt:)` 方法，内部复用现有的 `refine()` 分派逻辑（OpenAI / Anthropic / Ollama）
- 消除 `LLMClient` 内硬编码的 defaultPrompt（由 AppPreferences 统一管理默认值）

### TranscriptionViewModel Changes (`TranscriptionViewModel.swift`)

- Refine 调用改为读取 `AppPreferences.shared.refinePrompt()`
- Summary 调用入口预留（本次不实现完整 summary 流程，仅搭好结构）

## System-Wide Impact

### Interaction Graph
```
Settings UI → AppPreferences.setRefinePrompt / setSummaryPrompt → UserDefaults
TranscriptionViewModel → AppPreferences.refinePrompt → LLMClient.refine(text:customPrompt:)
                       → AppPreferences.summaryPrompt → LLMClient.summarize(text:customPrompt:)
```

### Error Propagation
- Prompt 为空时使用默认值，不抛错
- LLMClient 层错误处理不变（已有完整的 requestFailed / decodeFailed / networkFailed）

### State Lifecycle Risks
- 旧 Key `voicegum.llm.{provider}.prompt` 中的数据**不会自动迁移**。用户切换 Provider 后 Prompt 会变回默认值。影响很小（当前只有一个 Prompt 且通常不改）。

### API Surface Parity
- `refine()` 和新增的 `summarize()` 共享相同的 Provider 分派逻辑
- Anthropic / Ollama 的 summarize 路径直接复用现有方法

## Acceptance Criteria

- [ ] System Prompt 不再按 Provider 存储，切换 Provider 不改变 Prompt
- [ ] Refine Prompt 和 Summary Prompt 独立编辑、独立持久化
- [ ] 两个 Prompt 各有合理的默认值
- [ ] LLM 测试按钮仍然可用（使用 Refine Prompt 测试）
- [ ] Refine 功能端到端正常工作

## Dependencies & Risks

- **风险**：旧 UserDefaults 键残留。处理方式：不迁移，默认值兜底。
- **风险**：Summary 完整流程（结果展示、保存等）不在本次范围，仅搭 LLMClient 接口。

## Sources & References

### Internal References
- Provider 配置模式: `Sources/Preferences/AppPreferences.swift:79-119`
- LLMClient refine 分派: `Sources/Services/LLM/LLMClient.swift:88-107`
- Settings UI: `Sources/Core/SettingsView.swift:316-413`
- Refine 调用点: `Sources/Core/TranscriptionViewModel.swift:140-157`

### Origin
- 需求文档: `docs/brainstorms/2026-05-11-voicegum-macos-menu-bar-asr-requirements.md` — R4 LLM Refinement
