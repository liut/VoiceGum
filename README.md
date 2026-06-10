# VoiceGum

A minimal macOS application that transcribes audio files to text using configurable ASR engines, with optional LLM-powered refinement and summarization. Also includes a CLI for pipe-based transcription.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![SPM](https://img.shields.io/badge/Build-SPM-green)

## Features

### Audio Transcription
- **Drag & drop** or select audio files
- **Supported formats**: `wav`, `mp3`, `m4a`, `flac`, `aac`, `alac`, `aiff`, `caf`, `mp4`, `mov`, `m4v` (incl. audio-only video containers)
- **File size limits**: WAV ≤ 200 MB, other formats ≤ 60 MB
- **Multi-language support**: Chinese (Simplified / Traditional), English, Japanese, Korean
- **Real-time progress** indication with cancel support
- **Result export**: Copy to clipboard or auto-save to `~/Library/Application Support/VoiceGum/Result/`

### ASR Engines

| Type | Engine | Model | Notes |
|------|--------|-------|-------|
| Online | OpenAI | Whisper API (`whisper-1` / `whisper-large`) | OpenAI-compatible endpoints, API key in Keychain |
| Online | Volcano Engine | Streaming ASR | ByteDance cloud API, requires App ID / Access Token / Resource ID |
| Local | SenseVoice | GGUF (Q8_0 / FP16 / FP32) | In-process via ggml + Metal, auto-unloads after idle |

Local models are downloaded on demand from **HuggingFace** (primary) and **ModelScope** (mirror), with resume support for interrupted downloads.

### LLM Post-Processing
- **Text Refinement**: Auto-polish transcribed text (punctuation, formatting, error correction)
- **Summarization**: Generate concise summaries of transcriptions
- **Custom Prompts**: User-configurable system prompts for both tasks
- **Providers**: OpenAI-compatible, Anthropic, Ollama (local)
- **Trigger**: Automatic after transcription

### History & Management
- Persistent transcription history with raw text, refined text, and summaries
- Per-entry metadata: source file, engine used, language, duration

### CLI

```bash
# Transcribe a file
voicegum-cli audio.mp3

# Pipe audio from stdin
cat audio.mp3 | voicegum-cli

# Specify language and output file
voicegum-cli audio.mp3 -l zh -o out.txt
```

See `voicegum-cli --help` for full usage. Install with `make install-cli`.

## Build & Run

### Requirements
- macOS 14+
- Xcode 16+ / Swift 6 toolchain
- Apple Silicon (M1+) recommended for local models
- Apple Developer Program ($99/year) required for distribution signing and notarization. Local development works without it (`make run-app` uses ad-hoc signing)

### Commands

```bash
make build          # Build release binaries (GUI + CLI)
make run            # Run GUI from build output
make run-app        # Build, bundle, sign, and launch as .app
make run-cli        # Run CLI from build output
make install        # Install GUI app to /Applications
make install-cli    # Install CLI to /usr/local/bin
make clean          # Clean build artifacts
```

### Manual Build (SPM)

```bash
swift build -c release
```

Binaries are at `.build/release/VoiceGum` and `.build/release/VoiceGumCLI`.

## Configuration

### First Launch
1. Launch the app to open the main window.
2. Drop an audio file or click to select.
3. Go to **Settings → ASR** to choose your engine (online or local).
4. (Optional) Go to **Settings → LLM** to configure refinement / summarization.

### Local Models
Local models are stored in `~/Library/Application Support/VoiceGum/Models/<id>/`:

| Model | Size | Precision |
|-------|------|-----------|
| SenseVoice Q8_0 | ~230 MB | Quantized |
| SenseVoice FP16 | ~350 MB | Half-precision |
| SenseVoice FP32 | ~700 MB | Full-precision |

Models are downloaded from HuggingFace on first use. They auto-unload 5s after transcription finishes to free memory.

### LLM Settings
| Provider | Base URL | Requires API Key |
|----------|----------|------------------|
| OpenAI | `https://api.openai.com/v1` | ✅ |
| Anthropic | `https://api.anthropic.com` | ✅ |
| Ollama | `http://localhost:11434` | ❌ |

API keys are stored in **UserDefaults** (per-provider, configurable in Settings).

### Permissions
- **Microphone**: Reserved for future recording features. Not used by current build.


## License

Copyright © 2026 VoiceGum. All rights reserved.
