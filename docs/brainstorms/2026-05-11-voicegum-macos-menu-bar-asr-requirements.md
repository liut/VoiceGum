---
date: 2026-05-11
topic: voicegum-macos-menu-bar-asr
---

# VoiceGum — macOS 菜单栏语音转文字应用

## Problem Frame

macOS 用户需要一个极简的菜单栏应用，将音频文件（wav/mp3 等）快速转为文字，支持中文优先、离线模型灵活切换、以及 LLM 后处理润色。

## Requirements

- R1. **主窗口**
  - 支持选择文件按钮和拖放区域，接受 wav/mp3/m4a/flac 等格式
  - 确认后开始识别，动态进度条指示过程
  - 完成后显示可滚动、可拷贝的文本框；多文件时支持队列模式

- R2. **语言切换**
  - 默认语言 zh-CN，菜单栏提供切换选项：英语（en）、简体中文（zh-CN）、繁体中文（zh-TW）、日语（ja）、韩语（ko）
  - 语言偏好存储在 UserDefaults

- R3. **ASR 模型**
  - 支持在线 API 和离线模型：Whisper、SeamlessM4T、FunASR、Paraformer、SenseVoice
  - 离线模型提供精度选择（如有）和下载按钮
  - 模型选择存储在 UserDefaults

- R4. **LLM Refinement**
  - 菜单栏 LLM Refinement 子菜单：启用/禁用开关 + Settings 入口
  - Settings 窗口含 API Base URL、API Key（可清空）、Model 三个输入框，Test 和 Save 按钮
  - 同时支持本地直接运行和在线（OpenAI/Anthropic/Ollama/llama.cpp等）后端

- R5. **应用形态**
  - LSUIElement 模式运行（仅菜单栏图标，无 Dock 图标）
  - Swift Package Manager 构建
  - Makefile 提供 build/run/install/clean 目标，输出签名 .app bundle

## Success Criteria

- [x] 用户拖入音频文件 → 获得可拷贝文字
- [x] 语言切换即时生效，重启后保留
- [x] 离线模型可下载、切换、删除
- [x] LLM Settings 可配置、测试、启用/禁用
- [x] 应用仅在菜单栏运行，无 Dock 图标
- [x] Makefile 完整可用，构建产物已签名

## Scope Boundaries

- 不支持实时麦克风录音（仅文件输入）
- 不支持视频文件
- 不实现音频格式转换（依赖系统原生解码或 FFmpeg/AVFoundation）

## Key Decisions

- 多模型并行支持：通过灵活的模型抽象层同时支持 Whisper/SeamlessM4T/FunASR/Paraformer/SenseVoice，用户可运行时切换
- LLM 后端混合支持：同时支持本地和在线商业 API，通过 API Base URL 判断类型
- 主窗口内联 Refine 状态：小幅利用现有窗口面积，无需另起悬浮框
- 多文件队列处理：支持一次性拖入多个文件，排队识别，结果可滚动浏览

## Dependencies / Assumptions

- 离线模型下载依赖网络，可放在各自模型的管理面板中触发下载
- LLM 调用通过 OpenAI-compatible API，兼容 Ollama 和商业 API
- Apple Silicon (M1+) 构建环境，签名使用 Developer ID

## Outstanding Questions

### Resolve Before Planning
- **N/A** — 所有产品决策已通过对话澄清

### Deferred to Planning
- [技术] 确定各离线模型的具体集成路径（cpp binding / Swift binding / HTTP server bridge）
- [技术] Fn 键松开检测的具体实现方式（EventMonitor / CGEvent tap）
- [技术] 多文件队列的进度管理和结果聚合 UI 细节
- [技术] Makefile 签名机制的完整命令序列（entitlements、Developer ID、pkgbuild）
