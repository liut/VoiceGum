# VoiceGum

A minimal macOS application that transcribes audio files to text using configurable ASR engines, with optional LLM-powered refinement and summarization.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![SPM](https://img.shields.io/badge/Build-SPM-green)

## Overview

VoiceGum provides a fast, distraction-free way to convert speech in audio files into readable text. It supports both online APIs and local offline models, with an optional LLM post-processing pipeline for text refinement and summarization.

## Features

### Audio Transcription
- **Drag & drop** or select audio files (`wav`, `mp3`, `m4a`, `flac`, `aac`, `alac`, `aiff`, `caf`, and more)
- **Multi-language support**: Chinese (Simplified / Traditional), English, Japanese, Korean, Cantonese
- **Real-time progress** indication with cancel support
- **Result export**: Copy to clipboard or auto-save to `~/Library/Application Support/VoiceGum/Result/`

### ASR Engines

| Type | Engine | Model | Notes |
|------|--------|-------|-------|
| Online | OpenAI | Whisper API | OpenAI-compatible endpoints |
| Online | Volcano Engine | Streaming ASR | ByteDance cloud API |
| Local | SenseVoice | GGUF (Q8_0 / FP16 / FP32) | In-process via llama.cpp ggml + Metal |
Local models are downloaded on demand from **HuggingFace**, with resume support for interrupted downloads.

### LLM Post-Processing
- **Text Refinement**: Auto-polish transcribed text (punctuation, formatting, error correction)
- **Summarization**: Generate concise summaries of transcriptions
- **Custom Prompts**: User-configurable system prompts for both tasks
- **Providers**: OpenAI, Anthropic, Azure OpenAI, Ollama (local)
- **Trigger**: Automatic after transcription

### History & Management
- Persistent transcription history with raw text, refined text, and summaries
- Per-entry metadata: source file, engine used, language, duration

## Architecture

```
VoiceGum/
├── Sources/
│   ├── App/              # NSApplication entry point, AppDelegate
│   ├── Core/             # SwiftUI views, ViewModels, state machine
│   ├── Services/         # Transcription, LLM client, history, audio
│   ├── Preferences/      # UserDefaults wrapper
│   ├── Keychain/         # Keychain access for API keys
│   ├── FnKey/            # Fn key detector (menu bar toggle)
│   ├── CAsrEngine/       # SenseVoice ASR engine (ggml + Metal, C++17)
│   └── CZlib/            # Gzip helper for HTTP compression
├── Resources/
│   ├── Info.plist        # App bundle configuration (ATS, permissions)
│   └── AppIcon.icns      # App icon
├── Package.swift         # SPM manifest
└── Makefile              # build / run-app / install / clean
```

### Key Design Patterns

- **TranscriptionService Protocol**: Unified interface for all ASR backends (`GGMLTranscriptionService`, `OnlineAPITranscription`, `VolcanoEngineASR`)
- **TranscriptionState Enum**: State machine driving the UI (`idle → validating → queued → transcribing → refining → completed | failed | cancelled`)
- **Actor-based LLMClient**: Thread-safe singleton with provider-specific request builders (OpenAI, Anthropic, Ollama)
- **Actor-based ModelDownloadManager**: Resume-capable downloads with progress callbacks

## Build & Run

### Requirements
- macOS 14+
- Xcode 16+ / Swift 6 toolchain
- Apple Silicon (M1+) recommended for local models

### Commands

```bash
# Build release binary
make build

# Run directly from build output
make run

# Build and launch as signed .app bundle
make run-app

# Install to /Applications
make install

# Clean build artifacts
make clean
```

### Manual Build (SPM)

```bash
swift build -c release
```

The executable can be found at `.build/release/VoiceGum`.

## Configuration

### First Launch
1. Launch the app to open the main window.
2. Drop an audio file or click to select.
3. Go to **Settings → ASR** to choose your engine (online or local).
4. (Optional) Go to **Settings → LLM** to configure refinement / summarization.

### Local Models
Local models are stored in `~/Library/Application Support/VoiceGum/Models/`:

| Model | Size | Precision |
|-------|------|-----------|
| SenseVoice Q8_0 | ~230 MB | Quantized |
| SenseVoice FP16 | ~350 MB | Half-precision |
| SenseVoice FP32 | ~700 MB | Full-precision |

Models are downloaded from HuggingFace on first use.

### LLM Settings
| Provider | Base URL | Requires API Key |
|----------|----------|------------------|
| OpenAI | `https://api.openai.com/v1` | ✅ |
| Anthropic | `https://api.anthropic.com` | ✅ |
| Azure OpenAI | Your endpoint | ✅ |
| Ollama | `http://localhost:11434` | ❌ |

API keys are stored in **UserDefaults** (per-provider, configurable in Settings).

### Permissions
- **Microphone**: Used only if future recording features are enabled.


## License

Copyright © 2026 VoiceGum. All rights reserved.
