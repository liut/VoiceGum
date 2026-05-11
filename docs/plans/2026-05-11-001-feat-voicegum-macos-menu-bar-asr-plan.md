---
title: VoiceGum - macOS Menu Bar ASR App
type: feat
status: active
date: 2026-05-11
origin: docs/brainstorms/2026-05-11-voicegum-macos-menu-bar-asr-requirements.md
---

# VoiceGum — macOS Menu Bar ASR App

## Overview

A macOS menu bar only (LSUIElement) Swift application that transcribes audio files to text using configurable ASR models (online API or local offline models), with optional LLM refinement triggered by releasing the Fn key.

## Problem Frame

macOS users need a minimal, always-accessible menu bar app to transcribe audio files with:
- Chinese-language-first ASR (default zh-CN)
- Flexible ASR backend (online API + multiple offline models)
- LLM-powered text refinement post-processing

## Requirements Trace

- R1. 主窗口支持文件选择/拖放、动态进度指示、可滚动文本结果框、多文件队列
- R2. 菜单栏语言切换：en/zh-CN/zh-TW/ja/ko，默认 zh-CN，存储于 UserDefaults
- R3. ASR 模型选择（在线 API + 离线模型），支持精度选择和下载
- R4. LLM Refinement 子菜单：启用/禁用开关 + Settings（含 API Base URL / API Key / Model / Test / Save）
- R5. LSUIElement 运行模式、SPM 构建、签名 Makefile

## Scope Boundaries

- 文件输入仅支持音频格式（wav/mp3/m4a/flac 等），不支持实时录音或视频
- 不实现音频格式转换（依赖 AVFoundation 原生解码）
- 离线模型下载后本地运行，不通过网络传输音频

## Context & Research

### Relevant Code and Patterns

| Area | Pattern |
|------|---------|
| Menu bar | AppKit `NSStatusItem` + `NSMenu` in AppDelegate lifecycle |
| Window | `NSPopover` + `NSHostingController` with SwiftUI content |
| Drag & drop | `NSDraggingDestination` implemented in `NSView` subclass |
| LLM client | Native `async/await` URLSession，OpenAI-compatible API |
| Fn key | CGEvent tap with `.keyUp` for release detection |
| Progress | SwiftUI `ProgressView` + state machine |
| Settings | SwiftUI `TextField` + secure field，Keychain for API key |
| Preferences | `UserDefaults` via `@UserDefault` property wrapper |

### External References

- WhisperKit (Argmax): `https://github.com/argmax-oss/WhisperKit` — 纯 Swift Core ML 方案
- sherpa-onnx: `https://github.com/k2-fsa/sherpa-onnx` — 多模型支持（SenseVoice/Paraformer/Whisper）
- Ollama API: `http://localhost:11434/v1/chat/completions` — OpenAI-compatible，本地运行

## Key Technical Decisions

- **架构**: AppKit menu bar 入口 + SwiftUI 窗口内容（popover + sheet）
- **ASR 抽象层**: `TranscriptionService` protocol，支持在线 API（HTTP）、离线本地进程（whisper.cpp/sherpa-onnx 子进程）
- **LLM 客户端**: 统一 `LLMClient` actor，支持 OpenAI-compatible API，自动检测本地 Ollama（无 auth header）vs 在线 API（Bearer token）
- **API Key 安全存储**: Keychain（Security framework），不存储于 UserDefaults
- **进度状态机**: `TranscriptionState` enum（idle/preparing/transcribing/completed/failed）
- **Fn 键检测**: CGEvent tap（keycode 63 = Fn/F18），需 Accessibility 权限

## Open Questions

### Resolved During Planning

- **Q: 离线模型如何集成到 Swift app?** A: sherpa-onnx 提供 Swift API，或通过 Python HTTP server bridge（FunASR/SenseVoice 推荐此路径）。WhisperKit 为纯 Swift 备选。
- **Q: API Key 如何安全存储?** A: 使用 Keychain（Security framework），不写入 UserDefaults。
- **Q: LLM 在线/本地如何自动判断?** A: 通过 API Base URL 特征判断：`localhost`/`127.0.0.1` → 本地 Ollama（无需 API Key），其他 → 在线商业 API（Bear token）。

### Deferred to Implementation

- [技术] 多文件队列进度聚合 UI：队列进度 vs 单文件进度显示细节
- [技术] sherpa-onnx Swift binding 实际可用性和 API 细节

## Output Structure

```
VoiceGum/
├── Sources/
│   ├── App/
│   │   ├── main.swift                    # NSApplication.shared + AppDelegate 手动入口
│   │   └── AppDelegate.swift             # 菜单栏 + popover 初始化
│   ├── UI/
│   │   ├── MainWindow/
│   │   │   ├── MainView.swift            # 主窗口 SwiftUI 视图
│   │   │   ├── DropZoneView.swift        # 拖放区域 NSView + SwiftUI wrapper
│   │   │   ├── TranscriptionProgressView.swift
│   │   │   └── ResultTextView.swift      # 可滚动文本结果
│   │   ├── Settings/
│   │   │   └── LLMSettingsView.swift      # API Base/Key/Model 输入框
│   │   └── Components/
│   │       └── LanguagePicker.swift      # 语言切换菜单
│   ├── Services/
│   │   ├── Transcription/
│   │   │   ├── TranscriptionService.swift     # Protocol
│   │   │   ├── OnlineAPITranscription.swift    # HTTP API 实现
│   │   │   ├── WhisperTranscription.swift      # 本地 whisper.cpp/sherpa-onnx
│   │   │   └── TranscriptionState.swift      # 状态机
│   │   ├── LLM/
│   │   │   └── LLMClient.swift                 # OpenAI-compatible actor
│   │   └── Audio/
│   │       └── AudioFileValidator.swift        # 格式检查
│   ├── Keychain/
│   │   └── KeychainManager.swift         # API Key 读写
│   ├── Preferences/
│   │   └── AppPreferences.swift          # UserDefaults @UserDefault wrapper
│   └── FnKey/
│       └── FnKeyDetector.swift           # CGEvent tap Fn 键检测
├── Resources/
│   ├── Info.plist                        # LSUIElement=true
│   └── Assets.xcassets/                  # App 图标
├── project.yml                           # XcodeGen 配置（如需）
├── Makefile                             # build/run/install/clean + 签名
└── Package.swift                        # SPM 入口
```

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

### Transcription Flow

```
AudioFile → AudioFileValidator → TranscriptionService.transcribe()
                                              ↓
                              ┌───────────────┴────────────────┐
                              ↓                                 ↓
                    OnlineAPITranscription             WhisperTranscription
                    (URLSession POST)                   (local process)
                              ↓                                 ↓
                    ┌────────┴────────┐              sherpa-onnx / whisper.cpp
                    ↓                 ↓                subprocess
              Transcription      Transcription           ↓
                text               text                 ↓
                              ↓                         ↓
                              └────────────┬────────────┘
                                           ↓
                                   TranscriptionState.completed(text)
                                           ↓
                               ┌───────────┴───────────┐
                               ↓                       ↓
                     MainWindow display           LLMClient.refine(text)
                               (if LLM enabled + Fn released)
```

### State Machine (TranscriptionState)

```swift
enum TranscriptionState {
    case idle
    case validating(file: URL)
    case queued(files: [URL])          // 多文件队列
    case preparing(ASR: String)          // 准备 ASR
    case transcribing(progress: Double, currentFile: Int, totalFiles: Int)
    case refining                       // LLM 处理中
    case completed(text: String, files: [URL])
    case failed(error: Error)
}
```

### LLM Refine Flow (Fn Key Trigger)

```
用户释放 Fn 键
    ↓
FnKeyDetector 检测到 keyUp (keycode 63)
    ↓
检查 AppPreferences.llmEnabled && LLMClient.isConfigured()
    ↓
主窗口显示 "Refining..." 状态 (inline)
    ↓
LLMClient.refine(transcribedText) → OpenAI-compatible API
    ↓
返回 refined text → 注入到 ResultTextView
    ↓
状态切回 completed
```

## Implementation Units

- [ ] **Unit 1: 项目脚手架 + LSUIElement 配置**

**Goal:** 建立完整的 SPM 项目结构，菜单栏应用入口，LSUIElement 可运行

**Requirements:** R5

**Dependencies:** None

**Files:**
- Create: `Package.swift`
- Create: `Sources/App/main.swift`
- Create: `Sources/App/AppDelegate.swift`
- Create: `Resources/Info.plist`（含 LSUIElement）
- Create: `Resources/Assets.xcassets/`
- Create: `Makefile`

**Approach:**
- `Package.swift`: `package(name: "VoiceGum", products: [.executable("VoiceGum", targets: [.main])], targets: [...])`
- `main.swift`: `NSApplication.shared.delegate = AppDelegate(); app.run()` 无 `@main`
- `Info.plist` 后处理：通过 Makefile 的 `plutil` 命令注入到 .app bundle

**Patterns to follow:** AppKit menu bar pattern（research findings section 1）

**Test scenarios:**
- Happy path: 启动应用 → 菜单栏出现图标，无 Dock 图标
- Edge case: 无意况下权限提示正常触发

---

- [ ] **Unit 2: 主窗口 UI（拖放 + 进度 + 结果）**

**Goal:** 主 popover 窗口支持文件拖放、进度显示、多文件队列、结果可滚动文本框

**Requirements:** R1

**Dependencies:** Unit 1

**Files:**
- Create: `Sources/UI/MainWindow/MainView.swift`
- Create: `Sources/UI/MainWindow/DropZoneView.swift`
- Create: `Sources/UI/MainWindow/TranscriptionProgressView.swift`
- Create: `Sources/UI/MainWindow/ResultTextView.swift`
- Modify: `Sources/App/AppDelegate.swift`（注入 StatusBarController）

**Approach:**
- `DropZoneView`: `NSView` 实现 `NSDraggingDestination`，支持 wav/mp3/m4a/flac/aac/alac
- 状态机驱动 UI 切换：idle → validating → queued → transcribing → completed/failed
- 多文件时显示队列进度（当前文件 / 总文件）

**Patterns to follow:** research findings section 3 (drag & drop)

**Test scenarios:**
- Happy path: 拖入有效 wav 文件 → 文件名显示 → 开始识别
- Edge case: 拖入无效文件 → 错误提示
- Edge case: 拖入多个文件 → 队列进度显示
- Happy path: 识别完成 → 文本框显示可滚动结果
- Edge case: 超长文本 → 可滚动

---

- [ ] **Unit 3: 语言切换 + UserDefaults 偏好存储**

**Goal:** 菜单栏语言切换菜单，默认 zh-CN，偏好持久化

**Requirements:** R2

**Dependencies:** Unit 1

**Files:**
- Create: `Sources/Preferences/AppPreferences.swift`
- Create: `Sources/UI/Components/LanguagePicker.swift`
- Modify: `Sources/App/AppDelegate.swift`（插入语言子菜单）

**Approach:**
- `@UserDefault` property wrapper 封装 `UserDefaults.standard`
- 菜单栏 `NSMenu` 子菜单项对应 5 种语言
- 语言变更后更新 `AppPreferences.language`

**Patterns to follow:** research findings section 4

**Test scenarios:**
- Happy path: 首次启动默认 zh-CN
- Happy path: 切换语言后重启 → 保留上次选择
- Edge case: 无效语言值 → 回退到 zh-CN

---

- [ ] **Unit 4: ASR 服务抽象层 + 在线 API 实现**

**Goal:** TranscriptionService protocol + OnlineAPITranscription 实现，支持文件上传识别

**Requirements:** R3

**Dependencies:** Unit 2（UI 触发的转写流程）

**Files:**
- Create: `Sources/Services/Transcription/TranscriptionService.swift`
- Create: `Sources/Services/Transcription/OnlineAPITranscription.swift`
- Create: `Sources/Services/Transcription/TranscriptionState.swift`
- Create: `Sources/Services/Audio/AudioFileValidator.swift`

**Approach:**
- `TranscriptionService`: protocol `func transcribe(file: URL, language: String) async throws -> String`
- `OnlineAPITranscription`: URLSession POST multipart file + JSON response
- 语言代码映射：zh-CN → `zh`，en → `en`，ja → `ja`，ko → `ko`，zh-TW → `zh-TW`
- 支持 Whisper-compatible API 端点（openai/whisper、硅基流动等）

**Test scenarios:**
- Happy path: 发送 wav 到 API → 获得文字
- Error path: API 返回错误 → TranscriptionState.failed
- Edge case: 网络超时 → 错误处理

---

- [ ] **Unit 5: 离线 ASR 模型支持**

**Goal:** sherpa-onnx/Whisper 本地转写服务集成

**Requirements:** R3

**Dependencies:** Unit 4

**Files:**
- Create: `Sources/Services/Transcription/WhisperTranscription.swift`
- Create: `Sources/Services/Transcription/ModelDownloadManager.swift`

**Approach:**
- sherpa-onnx 本地进程调用（Swift → subprocess → stdout 获取结果）
- 模型下载状态管理：进度回调 → 存储路径 → UserDefaults 记录路径
- 精度选择：Base/Medium/High（如模型支持）
- 离线模型文件存储在 `~/Library/Application Support/VoiceGum/Models/`

**Patterns to follow:** sherpa-onnx Swift API 或 subprocess approach

**Test scenarios:**
- Happy path: 下载模型 → 显示进度 → 完成
- Edge case: 下载中断 → 恢复或重试
- Happy path: 使用离线模型转写 → 获得文字

---

- [ ] **Unit 6: LLM Settings + Keychain + Refine 逻辑**

**Goal:** LLM Settings 子菜单、API Key 安全存储、Fn 键松开触发 Refine

**Requirements:** R4

**Dependencies:** Unit 2, Unit 4

**Files:**
- Create: `Sources/Keychain/KeychainManager.swift`
- Create: `Sources/Services/LLM/LLMClient.swift`
- Create: `Sources/UI/Settings/LLMSettingsView.swift`
- Create: `Sources/FnKey/FnKeyDetector.swift`
- Modify: `Sources/App/AppDelegate.swift`（LLM 子菜单 + Settings sheet）

**Approach:**
- `LLMClient`: actor，自动判断 local（无 Authorization header）vs online（Bearer token）
- `LLMSettingsView`: 三个 `TextField`（最后一个为 secure） + Test + Save 按钮
- `FnKeyDetector`: CGEvent tap，keycode 63，`isEnabled` 控制是否监听
- Refine 触发流程见 High-Level Technical Design

**Patterns to follow:** research findings sections 3 (LLM) + 4 (Fn key)

**Test scenarios:**
- Happy path: Save API Key → 写入 Keychain
- Happy path: Test 按钮 → 发送测试请求 → 显示成功/失败
- Edge case: API Key 输入框可完全清空（删除所有字符）
- Happy path: Fn 键释放 + LLM 已启用 → 显示 Refining... → 注入结果
- Edge case: API Key 为空但 LLM 启用 → 禁用状态或错误提示

---

- [ ] **Unit 7: 菜单栏完整集成 + 多文件队列**

**Goal:** 完整菜单栏（语言切换 + ASR 模型切换 + LLM 子菜单），多文件队列处理

**Requirements:** R1, R2, R3, R4

**Dependencies:** Units 1-6

**Files:**
- Modify: `Sources/App/AppDelegate.swift`（完整菜单栏结构）
- Modify: `Sources/UI/MainWindow/MainView.swift`（多文件队列 UI）

**Approach:**
- 完整三层菜单结构：主菜单 → 语言/模型/LLM 设置
- 多文件队列：`queued` 状态 → 逐个处理 → 聚合结果
- LLM 子菜单：`启用 Refinement` 复选菜单项 + `Settings...` 菜单项

**Test scenarios:**
- Happy path: 所有菜单项可点击响应
- Edge case: LLM 未配置时 Settings 显示引导提示

---

- [ ] **Unit 8: Makefile 完整构建 + 签名**

**Goal:** 完整 Makefile（build/run/install/clean），签名 .app bundle

**Requirements:** R5

**Dependencies:** Units 1-7

**Files:**
- Modify: `Makefile`（补充完整 target）

**Approach:**
```makefile
build:
	swift build -c release

run:
	./.build/release/VoiceGum

install: build sign
	cp -r ./build/Release/VoiceGum.app /Applications/

sign:
	codesign --force --sign "$(DEVELOPER_ID)" \
		--options runtime \
		--entitlements ./Resources/VoiceGum.entitlements \
		./build/Release/VoiceGum.app

clean:
	rm -rf .build && rm -rf build
```

**Verification:**
- `make build` 成功无错误
- `make run` 启动应用，菜单栏图标出现，无 Dock 图标
- `make sign` + `make install` 产生已签名 .app

## System-Wide Impact

- **Entry point**: Menu bar icon click → NSPopover 显示
- **LSUIElement**: Info.plist 中 `LSUIElement=true`，需在 Makefile 后处理注入
- **Accessibility permission**: Fn key detection requires user-granted permission in System Settings → Privacy & Security → Accessibility
- **Keychain access**: App requests Keychain access on first LLM API Key save

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| CGEvent tap 在 macOS 未来版本行为变化 | 设计可拔插的 Fn 检测器接口，后续可切换到 NSEvent monitor |
| 离线模型打包体积大 | 模型不打包入 app，通过下载管理器按需下载 |
| LLM API 响应延迟 | async/await，非阻塞 UI，显示 Refining... 状态 |

## Documentation / Operational Notes

- 首次启动需要授权 Accessibility 权限（Fn 键检测）
- 首次 LLM Settings 需要用户手动配置 API Key
- 模型下载建议在 Wi-Fi 环境下进行
