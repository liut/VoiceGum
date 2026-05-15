# AGENTS.md — VoiceGum

## Build

```bash
swift build -c release
make run-app                     # build + bundle .app + ad-hoc sign + open
make clean                       # rm -rf .build build
```

- **SDKROOT**: If you see missing `MacOSX26.4.sdk`, unset SDKROOT or point to `xcrun --show-sdk-path`.
- **C++ compilation**: `CAsrEngine` uses `-fno-modules` to bypass Clang module errors from Xcode 26.5 SDK headers. Don't remove it.
- **Pre-built static libs**: `Sources/CAsrEngine/libs/libggml*.a` are Apple Silicon builds. Rebuild from llama.cpp if adding a new backend.

## Module Graph

```
VoiceGum (Sources/App)
  └─ VoiceGumCore (Sources/Core)
       ├─ VoiceGumServices (Sources/Services)
       │    ├─ VoiceGumPreferences
       │    ├─ VoiceGumKeychain
       │    ├─ CZlib (C, links libz)
       │    └─ CAsrEngine (C++17, links libggml*.a + Metal)
       ├─ VoiceGumPreferences
       ├─ VoiceGumKeychain
       └─ VoiceGumFnKey
```

`VoiceGumPreferences` has zero dependencies — no Services or Core imports.

## Conventions

- **ViewModel** = `@MainActor` class. **Service** = `actor` or `@unchecked Sendable` class.
- **State machine**: `TranscriptionState` enum → `MainView.body` switch. Add case → add branch → wire in ViewModel.
- **Provider dispatch**: string in UserDefaults → enum in code. Strings in `AppPreferences.Keys`, enum in service layer.
- **Inline request/response structs** inside functions are fine (see `LLMClient.swift`).
- **One concept per file**. `SettingsView.swift` is long but intentional.

## Adding Features

**New LLM Provider**: add case to `LLMProvider` → add `xxxChat()` method → update `send()` switch → add to `SettingsView.providers` → add `defaultBaseURL`/`defaultModel` → add to `validProviders`.

**New ASR Engine**: conform to `TranscriptionService` → dispatch in `setupTranscriptionService()` → UI in `ASRSettingsTab` → keys in `AppPreferences.Keys`.

**New Preference**: add key constant → computed property in `AppPreferences`. Validate stale identifiers on read (see `setupLocalService()`).

## Known Quirks

- **ggml Metal exclusivity**: Only one Metal backend per process. ASR engine uses ggml Metal; adding another Metal consumer (MLX, separate llama.cpp) will crash.
- **Model lifecycle**: `GGMLTranscriptionService` auto-unloads after 5s idle. Call `invalidateActiveModel()` before switching models.
- **UserDefaults keys**: `voicegum.` prefix, dot-separated. Per-provider: `voicegum.llm.<provider>.<field>`.
- **ASR API key**: Keychain. **LLM API keys**: UserDefaults.
- **`CAsrEngine` uses `unsafeFlags`** — SPM can't express C++17 + header paths natively. Expected.
- **`Sources/UI/`** — empty directories, no SPM target. Dead code.

## Data Locations

| What | Where |
|------|-------|
| Downloaded models | `~/Library/Application Support/VoiceGum/Models/<id>/` |
| Results + history | `~/Library/Application Support/VoiceGum/Result/` |
| UserDefaults | `UserDefaults.standard` (no suite name) |
| ASR API key | Keychain (`KeychainManager`) |
| LLM API keys | UserDefaults (`voicegum.llm.<provider>.apiKey`) |
