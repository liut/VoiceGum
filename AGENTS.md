# AGENTS.md — VoiceGum

## Build

```bash
swift build -c release
make run-app                     # build + bundle .app + ad-hoc sign + open
make run-cli                     # build + run CLI
make install-cli                 # cp VoiceGumCLI → /usr/local/bin/voicegum-cli
make clean                       # rm -rf .build build
```

- **SDKROOT**: If you see missing `MacOSX26.4.sdk`, unset SDKROOT or point to `xcrun --show-sdk-path`.
- **C++ compilation**: `CFunASREngine` uses `-fno-modules` to bypass Clang module errors from Xcode 26.5 SDK headers. Don't remove it.
- **Pre-built static libs**: `Sources/CFunASREngine/libs/libggml*.a` are Apple Silicon builds. Rebuild via `make funasr-libs` if updating llama.cpp.

## Architecture

```
VoiceGum/
├── Sources/
│   ├── App/              # NSApplication entry point, AppDelegate
│   ├── CLI/              # voicegum-cli (VoiceGumServices dependency only)
│   ├── Core/             # SwiftUI views, ViewModels, state machine
│   ├── Services/         # Transcription, LLM client, history, audio
│   │   ├── Audio/        # AudioFileValidator, AudioConverter
│   │   ├── History/      # HistoryManager
│   │   ├── LLM/          # LLMClient
│   │   └── Transcription/# ASR services, model download, logger
│   ├── Preferences/      # UserDefaults wrapper
│   ├── Keychain/         # Keychain access for ASR API key
│   ├── FnKey/            # Fn key detector
│   ├── CAsrEngine/       # [DEPRECATED] Legacy SenseVoice engine
│   ├── CFunASREngine/    # FunASR engine: SenseVoice + FunASR-Nano (ggml + Metal, C++17)
│   └── CZlib/            # Gzip helper for HTTP compression
├── Resources/            # GUI bundle resources (Info.plist, icons, assets)
├── Package.swift         # SPM manifest (VoiceGum + VoiceGumCLI products)
└── Makefile              # build / run-app / run-cli / install / clean
```

### Module Graph

```
VoiceGumCLI (Sources/CLI)
  └─ VoiceGumServices (Sources/Services)
       ├─ VoiceGumPreferences
       ├─ VoiceGumKeychain
       ├─ CZlib (C, links libz)
       └─ CFunASREngine (C++17, links libggml*.a + OpenMP)

VoiceGum (Sources/App)
  └─ VoiceGumCore (Sources/Core)
       ├─ VoiceGumServices
       ├─ VoiceGumPreferences
       ├─ VoiceGumKeychain
       └─ VoiceGumFnKey
```

`VoiceGumCLI` depends only on `VoiceGumServices` — no App/Core/UI linkage. `VoiceGumPreferences` has zero dependencies.

### Key Design Patterns

- **TranscriptionService Protocol**: Unified interface for all ASR backends (`FunASRTranscriptionService`, `FunASRNanoTranscriptionService`, `GGMLTranscriptionService`, `OnlineAPITranscription`, `VolcanoEngineASR`)
- **TranscriptionState Enum**: State machine driving the UI (`idle → validating → queued → preparing → transcribing → refining → completed | failed | cancelled`)
- **Actor-based LLMClient**: Thread-safe singleton with provider-specific request builders (OpenAI, Anthropic, Ollama)
- **Actor-based ModelDownloadManager**: Resume-capable downloads with progress callbacks
- **Background URLSession**: LLM calls run off the main queue to avoid "process not responding" during long requests

## Conventions

- **ViewModel** = `@MainActor` class. **Service** = `actor` or `@unchecked Sendable` class.
- **State machine**: `TranscriptionState` enum → `MainView.body` switch. Add case → add branch → wire in ViewModel.
- **Provider dispatch**: string in UserDefaults → enum in code. Strings in `AppPreferences.Keys`, enum in service layer.
- **Inline request/response structs** inside functions are fine (see `LLMClient.swift`).
- **One concept per file**. `SettingsView.swift` is long but intentional.

## Adding Features

**New Executable Target**: add product + target in `Package.swift`, choose minimal dependency set (see `VoiceGumCLI` for example: only `VoiceGumServices`).

**New LLM Provider**: add case to `LLMProvider` → add `xxxChat()` method → update `send()` switch → add to `SettingsView.providers` → add `defaultBaseURL`/`defaultModel` → add to `validProviders`.

**New ASR Engine**: conform to `TranscriptionService` → dispatch in `setupTranscriptionService()` → UI in `ASRSettingsTab` → keys in `AppPreferences.Keys`.

**New Preference**: add key constant → computed property in `AppPreferences`. Validate stale identifiers on read (see `setupLocalService()`).

## Known Quirks

- **ggml Metal exclusivity**: Only one Metal backend per process. Encoder creates + frees its backend before LLM init to avoid conflict. Adding another Metal consumer (MLX, separate llama.cpp) will crash.
- **Model lifecycle**: `GGMLTranscriptionService` auto-unloads after 5s idle. Call `invalidateActiveModel()` before switching models.
- **UserDefaults keys**: `voicegum.` prefix, dot-separated. Per-provider: `voicegum.llm.<provider>.<field>`.
- **ASR API key**: Keychain. **LLM API keys**: UserDefaults.
- **`CFunASREngine` uses `unsafeFlags`** — SPM can't express C++17 + header paths natively. Expected.
- **`Sources/UI/`** — empty directories, no SPM target. Dead code.
- **`_exit(0)` in AppDelegate + CLI**: Bypasses ggml Metal static destructor crash. Don't replace with normal `exit()`.
- **`Logger` writes to stderr**: Both GUI console and CLI stderr — intentional, keeps stdout clean for CLI pipe output.

## Data Locations

| What | Where |
|------|-------|
| Downloaded models | `~/Library/Application Support/VoiceGum/Models/<id>/` |
| Results + history | `~/Library/Application Support/VoiceGum/Result/` |
| UserDefaults | `UserDefaults.standard` (no suite name) |
| ASR API key | Keychain (`KeychainManager`) |
| LLM API keys | UserDefaults (`voicegum.llm.<provider>.apiKey`) |
