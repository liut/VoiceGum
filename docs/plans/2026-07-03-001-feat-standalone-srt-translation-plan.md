---
title: feat: Add standalone SRT subtitle translation menu item
type: feat
status: active
date: 2026-07-03
origin: docs/brainstorms/2026-07-03-standalone-srt-translation-requirements.md
---

# feat: Add standalone SRT subtitle translation menu item

## Summary

Add a "翻译字幕文件..." menu item that opens an existing SRT file, translates it via the configured LLM, and saves the translated SRT alongside the original. The feature reuses `LLMClient.translate()` and `SubtitleFormatter` — the only new logic is an SRT parser and a lightweight translation pipeline manager, plus a modal progress window.

---

## Problem Frame

VoiceGum's translation infrastructure (`LLMClient.translate()`, `SubtitleFormatter`, translation preferences) is only accessible through the transcription pipeline. Users who already have SRT files (from other tools or shared by others) cannot use VoiceGum's LLM translation without re-transcribing audio — which is impossible when only the subtitle file exists.

(see origin: `docs/brainstorms/2026-07-03-standalone-srt-translation-requirements.md`)

---

## Requirements

**Menu & file selection**
- R1. Menu item "翻译字幕文件..." with Cmd+Shift+T, always available
- R2. NSOpenPanel filtering `.srt` / `.txt`, single file only

**SRT parsing**
- R3. Parse standard SRT format (index, `HH:MM:SS,mmm --> HH:MM:SS,mmm`, multi-line text) → `[SubtitleSegment]`
- R4. Show clear error for incompatible format

**Translation execution**
- R5. Reuse `LLMClient.translate()` with existing preferences (target language, mode batch/per-segment, output mode bilingual/translation-only, custom prompt)
- R6. Reuse `SubtitleFormatter.toSRT()` / `toSRTBilingual()` for output generation

**Output file**
- R7. Name: `{原文件名}_{YYYYMMDD-HHmmss}.{语言代码}.srt`, same directory as source, silent overwrite

**Progress & feedback**
- R8. Modal progress window showing X/N and cancel button
- R9. Completion alert with output file path
- R10. Cancel stops remaining LLM calls, no partial output file

**Error handling**
- R11. LLM not configured → alert "请先在设置中配置 LLM"
- R12. LLM call failure → alert with error detail, no partial file
- R13. Empty SRT (0 segments) → alert "文件中未找到有效字幕"

**Origin actors:** A1 (用户), A2 (LLM 服务)
**Origin flows:** F1 (独立 SRT 翻译), F2 (翻译失败处理)
**Origin acceptance examples:** AE1 (happy path 50 segments), AE2 (bilingual output), AE3 (batch mode), AE4 (LLM not configured), AE5 (invalid file), AE6 (cancel), AE7 (empty file), AE8 (silent overwrite)

---

## Scope Boundaries

- No SRT preview or editing UI
- No multi-file batch translation
- No non-SRT formats (ASS, VTT)
- No HistoryManager integration
- No CLI support
- No coupling with the transcription→translation pipeline
- No settings page changes

### Deferred to Follow-Up Work

- CLI `voicegum-cli translate-srt` command: separate PR in `Sources/CLI/`

---

## Context & Research

### Relevant Code and Patterns

| Asset | Path | Role |
|-------|------|------|
| Menu structure | `Sources/App/VoiceGumApp.swift` | `CommandGroup(after: .newItem)` + `Button` + `keyboardShortcut` |
| File dialog | `Sources/App/AppDelegate.swift` (L92-100) | `NSOpenPanel` with `allowedContentTypes` + `runModal()` |
| NSWindow creation | `Sources/App/AppDelegate.swift` (L113-150) | `NSHostingController` → `NSWindow` with stored reference |
| LLM translate | `Sources/Services/LLM/LLMClient.swift` (L198) | `actor LLMClient.shared.translate(text:targetLanguage:customPrompt:)` |
| SRT output | `Sources/Services/Transcription/SubtitleFormatter.swift` | `toSRT()`, `toSRTBilingual()`, `formatTime()`, `splitByLanguage()` |
| SubtitleSegment | `Sources/Services/Transcription/TranscriptionTypes.swift` | `text: String, startMs: Float, endMs: Float, language: String?` |
| TranslateMode/OutputMode | `Sources/Preferences/AppPreferences.swift` | `batch`/`perSegment`, `bilingual`/`translationOnly` |
| Translation pipeline reference | `Sources/Core/TranscriptionViewModel.swift` (L450-550) | `performTranslation()`, `chunkSegments()`, `parseTranslatedSegments()` |
| Task orchestration reference | `Sources/Core/TranscriptionViewModel.swift` (L370-404) | `refine()` — `Task.detached` + `[weak self]` + cancellation |
| Progress UI reference | `Sources/Core/StateViews.swift` | `TranslatingView`, `RefiningView` (spinner patterns) |
| NSPanel reference | `Sources/VoiceInput/VoiceInputOverlayWindow.swift` | floating panel pattern |

### Institutional Learnings

- No `docs/solutions/` directory exists. All relevant patterns are in the plan files and source code referenced above.
- The SRT parser is the only new algorithm — everything else reuses existing infrastructure.
- Batch mode relies on `[SEGMENT N]` markers and `parseTranslatedSegments()` from `TranscriptionViewModel` — the translation manager should replicate this chunking/parsing logic, not call into the ViewModel.

---

## Key Technical Decisions

- **SRT parser as new file `SRTParser.swift`**: Keeps `SubtitleFormatter` output-only (~600 lines already). One concept per file per AGENTS.md convention.
- **Dedicated `@MainActor class SRTTranslationManager`**: Separates translation orchestration from AppDelegate's window management. AppDelegate already manages settings window, history window, and transcription lifecycle — adding a 4th concern would bloat it.
- **Modal progress window**: Blocks main window interaction during translation, matching the simple workflow. Non-modal adds complexity (concurrent transcription + translation edge cases) for no user benefit at this scope.
- **UTF-8 only**: Standard for SRT files; non-UTF-8 encodings are rare in practice. Parse failures from encoding issues surface as "无法解析该文件".
- **LLM config check after file selection**: Alert after user picks a file if LLM isn't configured (matches AE4 from origin: "点击菜单项 → 选择 SRT 文件 → 弹窗"). Letting the user see the file dialog first avoids a dead-end UX where the menu item silently does nothing.

---

## Open Questions

### Resolved During Planning

- Q: Should the translation manager replicate chunking/parsing logic or call into TranscriptionViewModel? → A: Replicate. TranscriptionViewModel is a @MainActor ViewModel tied to the transcription state machine; the standalone manager should be self-contained.
- Q: Should NSOpenPanel filter by `.srt` UTT type or `.plainText`? → A: `.plainText` (`.srt` is not a built-in UTType). Filter displayed files by extension in the panel's accessory view or rely on the parser's format validation.

### Deferred to Implementation

- Exact regex or parsing strategy for SRT format (line-splitting vs. regex — both are valid, impl decides based on edge case handling)
- Maximum file size guard (parse first, measure segment count, decide threshold)
- Batch chunk size (reuse 80 from `TranscriptionViewModel.chunkSegments()` as default, tune if needed)

---

## Implementation Units

### U1. SRT Parser

**Goal:** Parse SRT text into `[SubtitleSegment]`, with clear error reporting for invalid input.

**Requirements:** R3, R4

**Dependencies:** None

**Files:**
- Create: `Sources/Services/Transcription/SRTParser.swift`
- Test: `Tests/VoiceGumServicesTests/SRTParserTests.swift`

**Approach:**
- Public enum namespace (matching `SubtitleFormatter` pattern): `public enum SRTParser { static func parse(_ content: String) throws -> [SubtitleSegment] }`
- Define a `SRTParseError` enum: `invalidFormat`, `emptyFile`
- Split input by double-newline (`\n\n` or `\r\n\r\n`) to get blocks
- For each block: extract index (line 1), timecode (line 2), text (remaining lines)
- Parse timecode: `HH:MM:SS,mmm --> HH:MM:SS,mmm` → startMs/endMs as Float
- Discard the `language` field (set to `nil` — source SRT has no language metadata)

**Patterns to follow:**
- `SubtitleFormatter.swift` — enum-with-static-methods namespace pattern, `formatTime()` for the inverse operation

**Test scenarios:**
- Happy path: single segment with single-line text → correct `SubtitleSegment` with matching text, startMs, endMs
- Happy path: multi-segment SRT with multi-line text per segment → all segments parsed, multi-line text joined with newlines
- Happy path: SRT with trailing blank lines → same result as without (blank lines trimmed)
- Edge case: CRLF line endings (`\r\n`) → parsed identically to LF
- Edge case: UTF-8 BOM at start of file → BOM stripped, parsing succeeds
- Edge case: variable whitespace around the `-->` arrow → normalized, parsing succeeds
- Edge case: segment with no text (just index + timecode) → segment included with empty text string
- Error path: completely empty string → throws `emptyFile`
- Error path: non-SRT content (plain text, binary garbage) → throws `invalidFormat`
- Error path: malformed timecode (`00:00:00 --> 00:00:05` missing comma/milliseconds) → throws `invalidFormat`
- Integration: parsed segments → `SubtitleFormatter.toSRT()` → re-parsed → same segments (round-trip)

**Verification:**
- All test scenarios pass
- `SRTParser.parse()` is accessible from `VoiceGumServices` module (public API)

---

### U2. Translation Pipeline Manager

**Goal:** Orchestrate the full SRT translation pipeline — parse, translate (per-segment or batch), format, and write — with cancellation support.

**Requirements:** R5, R6, R7, R10, R11, R12

**Dependencies:** U1

**Files:**
- Create: `Sources/Services/Transcription/SRTTranslationManager.swift`
- Test: `Tests/VoiceGumServicesTests/SRTTranslationManagerTests.swift`

**Approach:**
- `@MainActor public final class SRTTranslationManager` — MainActor because it drives UI progress updates
- Public method: `func translate(file url: URL, progress: @Sendable (Int, Int) -> Void) async throws -> URL`
  - Reads file contents at `url` via `String(contentsOf: url, encoding: .utf8)`
  - Parses via `SRTParser.parse()`
  - Checks LLM configuration: read provider/model/baseURL/apiKey from `AppPreferences`, call `await LLMClient.shared.configure(provider:baseURL:apiKey:model:)` (following `TranscriptionViewModel.configureLLMClient()` at L767-781), then verify via `await LLMClient.shared.isConfigured()`
  - If not configured → throw `SRTTranslationError.llmNotConfigured`
  - Iterates segments per `TranslateMode` preference:
    - **per-segment**: loop over segments, `await LLMClient.shared.translate(text: seg.text, ...)`, update progress after each
    - **batch**: chunk segments (max 80 per chunk via `chunkSegments()`), wrap in `[SEGMENT N]` markers, translate each chunk, parse back via `parseTranslatedSegments()`
  - Check `Task.isCancelled` between segments/chunks — if cancelled, throw `CancellationError`
  - Format output via `SubtitleFormatter.toSRT()` or `.toSRTBilingual()` per `TranslateOutputMode`
  - Construct output URL: `{sourceDir}/{stem}_{YYYYMMDD-HHmmss}.{langSuffix}.srt`
  - Write via `try outputStr.write(to: outputURL, atomically: true, encoding: .utf8)`
  - Return output URL

- Chunking/parsing helpers replicate the logic from `TranscriptionViewModel`:
  - `chunkSegments(_ segments: [SubtitleSegment], maxPerChunk: Int) -> [[SubtitleSegment]]`
  - `parseTranslatedSegments(_ raw: String, original: [SubtitleSegment]) -> [SubtitleSegment]`

**Patterns to follow:**
- `TranscriptionViewModel.performTranslation()` (L450-550) — chunk+parse logic, progress tracking
- `TranscriptionViewModel.refine()` (L370-404) — `Task.detached` + `[weak self]` + cancellation
- `TranscriptionViewModel.generateTranslatedSRT()` — file naming convention (timestamp + language suffix)

**Test scenarios:**
- Happy path: valid SRT file, per-segment mode, English → Chinese → output file at expected path with correct naming
- Happy path: valid SRT file, batch mode, all segments translated, output matches original segment count
- Happy path: bilingual output mode → each subtitle block has original + translated text
- Edge case: single segment → one LLM call, one output segment
- Edge case: 100+ segments in batch mode → chunked into multiple LLM calls, all segments recovered
- Error path: LLM not configured → throws `llmNotConfigured` (tested with mock/pref state)
- Error path: LLM call fails mid-way → error propagated, no output file written
- Error path: source file missing → `String(contentsOf:)` throws, error propagated
- Error path: parse failure → error from U1 propagated
- Integration: cancel during translation (set `Task.isCancelled`) → remaining LLM calls skipped, no output file, `CancellationError` thrown
- Integration: output file naming → `movie.srt` with target `zh-CN` → `movie_YYYYMMDD-HHmmss.zh-CN.srt`

**Verification:**
- All test scenarios pass
- Manager correctly reads `AppPreferences` for translate mode, output mode, target language, custom prompt
- Output SRT is valid and re-parseable by U1's parser

---

### U3. Menu Item & File Dialog

**Goal:** Add "翻译字幕文件..." to the menu bar with Cmd+Shift+T shortcut, wired to an NSOpenPanel for SRT file selection.

**Requirements:** R1, R2

**Dependencies:** U2

**Files:**
- Modify: `Sources/App/VoiceGumApp.swift`
- Modify: `Sources/App/AppDelegate.swift`

**Approach:**
- In `VoiceGumApp.swift`, add to the `.commands` block:
  - New `Button("翻译字幕文件...")` in the existing `CommandGroup(after: .newItem)` (next to "打开音频文件...")
  - `.keyboardShortcut("t", modifiers: [.command, .shift])`
  - Action: `appDelegate.translateSRTFile()`
- In `AppDelegate.swift`, add:
  - `func translateSRTFile()` — runs NSOpenPanel with `allowedContentTypes: [.plainText]`, single selection, directory disabled
  - On OK: check LLM config first → if not configured, show NSAlert and return
  - Then launch the translation pipeline (U2 + U4)

**Patterns to follow:**
- `AppDelegate.openFile()` (L92-100) — NSOpenPanel pattern
- Existing `CommandGroup(after: .newItem)` in `VoiceGumApp.swift` — placement and localization pattern

**Test scenarios:**
- Happy path: Cmd+Shift+T opens file dialog, selecting a `.srt` file starts translation
- Edge case: user cancels file dialog → no action, no alert
- Edge case: selecting a `.txt` file → accepted (allowedContentTypes includes plain text)

**Verification:**
- Menu item visible and enabled at all times (regardless of transcription state)
- Cmd+Shift+T triggers file dialog
- Only `.srt` and `.txt` files selectable

---

### U4. Progress Window

**Goal:** Show a modal progress window during translation with segment-level progress and a cancel button.

**Requirements:** R8, R9, R10

**Dependencies:** U2

**Files:**
- Create: `Sources/App/TranslationProgressView.swift`
- Modify: `Sources/App/AppDelegate.swift`

**Approach:**
- Create a SwiftUI view `TranslationProgressView`:
  - `@ObservedObject var manager: SRTTranslationManager` (or pass progress/cancel as bindings)
  - `ProgressView(value: Double(current), total: Double(total))` + text "正在翻译… X/N"
  - "取消" button → sets a `cancelled` flag / calls `task.cancel()`
  - On completion: dismiss window, show NSAlert "翻译完成" with output path + "在 Finder 中显示" button
- AppDelegate manages the window:
  - `var translationProgressWindow: NSWindow?` stored reference (matching settings/history window pattern)
  - Reuse existing window if visible, otherwise create with `NSHostingController(rootView: TranslationProgressView(...))`
  - `styleMask: [.titled, .closable]`, `level: .floating`
  - On close (user clicks X) → treat as cancel
  - After completion or cancel → close window, nil the reference

**Patterns to follow:**
- `AppDelegate.showSettings()` / `openHistory()` — NSHostingController + NSWindow creation + stored reference
- `StateViews.TranslatingView` — spinner + text layout
- `StateViews.TranscriptionProgressView` — progress bar + cancel button pattern

**Test scenarios:**
- Happy path: 50 segments → window shows "正在翻译… 1/50" through "50/50", then completion alert
- Edge case: very fast translation (1-2 segments) → window appears briefly, progress updates, window dismisses
- Integration: click cancel at 20/50 → window closes, no output file, no completion alert
- Integration: click window close button (X) → same as cancel
- Integration: completion alert "在 Finder 中显示" button → opens Finder at output file location

**Verification:**
- Progress window appears immediately after file selection
- Progress text updates per completed segment
- Cancel stops translation and dismisses window
- Completion alert is shown after all segments translated

---

### U5. Error Handling & Integration Wiring

**Goal:** Wire all error paths to user-facing NSAlert dialogs and ensure clean resource cleanup on all exit paths.

**Requirements:** R11, R12, R13

**Dependencies:** U2, U3, U4

**Files:**
- Modify: `Sources/App/AppDelegate.swift`
- Modify: `Sources/Services/Transcription/SRTTranslationManager.swift`

**Approach:**
- In AppDelegate's `translateSRTFile()`, wrap the pipeline call in a do-catch:
  - `SRTTranslationError.llmNotConfigured` → NSAlert "请先在设置中配置 LLM"
  - `SRTParseError.emptyFile` → NSAlert "文件中未找到有效字幕"
  - `SRTParseError.invalidFormat` → NSAlert "无法解析该文件，请确认其为有效的 SRT 字幕文件"
  - `LLMClientError` → NSAlert with localized description from the error
  - `CancellationError` → silent (user initiated cancel, no alert needed)
  - Generic error → NSAlert with `error.localizedDescription`
- In `SRTTranslationManager`:
  - Define `SRTTranslationError` enum: `llmNotConfigured`
  - Map `LLMClientError.notConfigured` to `SRTTranslationError.llmNotConfigured`
  - On any error after translation has started → ensure no partial output file is written
  - On cancellation → ensure no partial output file is written

**Patterns to follow:**
- `TranscriptionViewModel.exportSubtitles()` (L784-808) — NSAlert on file write failure
- Existing NSAlert patterns in the codebase — informative text + OK button

**Test scenarios:**
- Error path: LLM provider set but no API key → shows "请先在设置中配置 LLM" alert
- Error path: invalid SRT file selected → shows "无法解析该文件" alert
- Error path: empty SRT file selected → shows "文件中未找到有效字幕" alert
- Error path: LLM API returns error (network, auth) → shows alert with specific error message
- Error path: cancel during translation → no alert, no file written
- Integration: any error before translation starts → no progress window shown
- Integration: error mid-translation → progress window dismissed, error alert shown, no partial file

**Verification:**
- All error alerts are shown on the main thread
- No orphaned progress windows after error or cancel
- No partial/broken output files left on disk after any failure path

---

## System-Wide Impact

- **Interaction graph:** New menu item calls AppDelegate → SRTTranslationManager → LLMClient. No callbacks into TranscriptionViewModel or the transcription state machine.
- **Error propagation:** Errors map to NSAlert in AppDelegate. SRTTranslationManager throws typed errors; AppDelegate catches and displays.
- **State lifecycle risks:** The progress window reference in AppDelegate must be nilled on all exit paths (completion, error, cancel). The `Task` in SRTTranslationManager must be cancellable.
- **API surface parity:** No other interfaces affected. The feature is self-contained.
- **Integration coverage:** The full menu→file→translate→save pipeline should be manually tested end-to-end with a real LLM provider.
- **Unchanged invariants:** `LLMClient.translate()` unchanged. `SubtitleFormatter` unchanged. `AppPreferences` unchanged. Transcription pipeline unchanged. Existing SRT export from history unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Large SRT files (500+ segments) may cause long translation times in per-segment mode | Progress window shows progress; cancel is always available. Batch mode available as faster alternative. |
| SRT files with non-standard formatting may fail to parse | Parser handles common variants (whitespace, BOM, CRLF). Unparseable files get a clear error message. |
| ggml Metal backend conflict if transcription is running | Modal window prevents concurrent transcription start. If transcription is already running, translation queues naturally (separate LLMClient, no ggml conflict since translate() doesn't use Metal). |

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-07-03-standalone-srt-translation-requirements.md](../brainstorms/2026-07-03-standalone-srt-translation-requirements.md)
- Related code: `Sources/Services/LLM/LLMClient.swift`, `Sources/Services/Transcription/SubtitleFormatter.swift`, `Sources/Core/TranscriptionViewModel.swift`, `Sources/App/VoiceGumApp.swift`, `Sources/App/AppDelegate.swift`
- Related plan: [docs/plans/2026-06-25-002-feat-auto-translation-plan.md](2026-06-25-002-feat-auto-translation-plan.md) (auto-translation infrastructure this feature reuses)
