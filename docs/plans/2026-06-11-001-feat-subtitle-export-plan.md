---
title: feat: Add SRT subtitle export from transcription results
type: feat
status: active
date: 2026-06-11
origin: docs/brainstorms/2026-06-11-subtitle-export-requirements.md
---

# feat: Add SRT subtitle export from transcription results

## Summary

Extend the SenseVoice C API to expose VAD segment timing data (currently discarded), transcribe each segment individually, and produce SRT subtitle files both automatically on transcription completion and manually from the history view. The feature is scoped to the local GGML engine only — online ASR APIs do not return segment timing data.

---

## Problem Frame

VoiceGum transcribes audio/video to plain text but discards the VAD speech-segment timing data (`t0`/`t1`) that the engine computes internally. Users who need subtitles must manually segment the output and guess timecodes. This plan exposes that existing data and formats it as SRT.

(Full motivation in origin: `docs/brainstorms/2026-06-11-subtitle-export-requirements.md`)

---

## Requirements

- R1. C API extended to return segment timing + text per VAD segment
- R2. `TranscriptionResult` carries optional `[SubtitleSegment]`
- R3. SRT auto-generated to result directory on transcription completion with timestamp-suffix naming
- R4. Manual export button in history detail view, `NSSavePanel` for save location
- R5. `HistoryEntry` persists optional `segments` field
- R6. Old history records without segments: export button disabled
- R7. SRT format: sequential index, `HH:MM:SS,mmm --> HH:MM:SS,mmm` timecodes, UTF-8, blank-line separated
- R8. Merging short segments (<0.3s) into adjacent
- R9. Backward-compatible: old app versions silently ignore unknown `segments` key
- R10. Splitting long segments (>7s or >84 chars) at punctuation or break points

**Origin actors:** System (auto-generation), User (manual export)

**Origin flows:** F1 (auto-generate on completion), F2 (manual NSSavePanel export)

**Origin acceptance examples:** AE1 (3-segment SRT, correct timecodes), AE2 (history export matches auto-generated timecodes), AE3 (old records: button disabled)

---

## Scope Boundaries

- VTT, ASS, and other subtitle formats
- Word-level timestamps (no CTC forced alignment)
- Subtitle preview or editing UI
- Subtitles from refined/summary text — only rawText
- Batch export of multiple history entries
- Subtitle generation from online ASR engines (no segment data available)

---

## Context & Research

### Relevant Code and Patterns

- **C API header**: `Sources/CAsrEngine/include/asr_engine.h` — defines `sv_transcribe()`, `asr_progress_fn` callback pattern
- **VAD adapter**: `Sources/CAsrEngine/sense_voice_adapter.cpp` — VAD produces `sense_voice_segment` with `t0`/`t1` sample offsets, currently discarded after batch concatenation
- **VAD segment struct**: `Sources/CAsrEngine/private_headers/common.h` (line 298-306) — `sense_voice_segment { t0, t1, tokens, samples }`
- **GGML service**: `Sources/Services/Transcription/GGMLTranscriptionService.swift` — bridges C API to Swift async/await, currently returns `TranscriptionResult(text:timestamps:nil:...)`
- **TranscriptionResult**: `Sources/Services/Transcription/TranscriptionTypes.swift` (line 3-15) — `Sendable, Codable`, has unused `timestamps: [Float]?`
- **HistoryEntry**: `Sources/Services/Transcription/TranscriptionTypes.swift` (line 17-51) — `Codable, Identifiable, Sendable` value type, reconstructed via full init on mutations
- **HistoryManager**: `Sources/Services/History/HistoryManager.swift` — `actor` singleton, JSON persistence via `Codable`
- **TranscriptionViewModel**: `Sources/Core/TranscriptionViewModel.swift` — `@MainActor`, state machine, sets `.completed` at line 242/256, `saveResults()` at line 330
- **ResultView toolbar**: `Sources/Core/StateViews.swift` (line 126-151) — Summary/Copy/New File buttons in HStack
- **HistoryDetailView**: `Sources/Core/HistoryView.swift` — metadata display + copy buttons per section
- **NSOpenPanel pattern**: `Sources/App/AppDelegate.swift` (line 67-74) — `NSOpenPanel` with content type filter, precedent for NSSavePanel
- **AudioConverter**: `Sources/Services/Audio/AudioConverter.swift` — `AVAsset` reads both audio and video containers, extracts audio track
- **Package.swift**: Module graph — `VoiceGumCLI` → `VoiceGumServices` only; `VoiceGum` → `VoiceGumCore` → `VoiceGumServices`

### Institutional Learnings

No prior learnings in `docs/solutions/` — this is the first subtitle/export feature in the codebase.

Adjacent plan context:
- `docs/plans/2026-05-14-001-feat-transcription-history-plan.md`: HistoryEntry is persisted as flat `[HistoryEntry]` JSON array. Optional Codable field (`[Segment]?`) automatically decodes to `nil` when key is absent — no migration needed.
- `docs/plans/2026-05-14-003-feat-unified-ggml-asr-engine-plan.md`: C API is the single unified interface — extend it rather than creating parallel headers.

### External References

None — local patterns are comprehensive.

---

## Key Technical Decisions

- **Per-segment ASR with batching fallback for long audio**: Default to per-segment transcription (one `sense_voice_full_parallel()` call per VAD segment) to preserve text-to-timing mapping. When segment count exceeds 10 (long-form audio), switch to 30s batch mode: concatenate segments within each 30s window with 200ms silence padding, transcribe each batch as one call, then distribute the batch's output text back to individual segments proportionally by segment duration. This bounds ASR calls to `ceil(total_seconds / 30)` regardless of audio length. Per-segment mode is retained for short/medium audio where accuracy of text-to-segment alignment matters most.
- **New C function, not modified return**: `sv_transcribe_segments()` as a separate function avoids changing the existing `sv_transcribe()` contract. The existing function remains for the pure-text path (CLI, Online API fallback).
- **Segments embedded in HistoryEntry, not sidecar files**: Single source of truth. The data volume is small (N segments × ~100 bytes each). No file-management complexity.
- **Timestamp-suffix naming**: `meeting_20260611T143021.srt` avoids silent overwrites when the same source file is re-transcribed. Uses `ISO8601DateFormatter` with `withInternetDateTime`.
- **SRT formatter as pure function**: `[SubtitleSegment] → String`, no side effects, directly unit-testable. Merge logic (<0.3s) and split logic (>7s / >84 chars) live here.

---

## Open Questions

### Resolved During Planning

- C API shape: independent `sv_transcribe_segments()` function returning struct array — resolved per Key Technical Decisions
- Segment-to-text mapping: per-segment ASR calls — resolved per Key Technical Decisions
- Persistence format: embedded JSON array in HistoryEntry — resolved per Key Technical Decisions

### Deferred to Implementation

- [Affects R8/R10][Needs research] Whether 0.3s merge and 7s/84-char split thresholds need language-specific tuning — evaluate with real multi-language audio after implementation
- Exact error-alert wording for write failures and old-record export — implementation details, not architectural

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Data flow (auto-generation path):**

```
Audio file → VAD (silero) → [Segment{t0, t1, samples}]
  → for each segment: sense_voice_full_parallel(segment.samples) → text
  → [(text, t0, t1)] → TranscriptionResult.segments
  → SubtitleFormatter.toSRT(segments) → .srt file
  → HistoryEntry(segments: segments) → history.json
```

**C API extension:**

```c
// New struct in asr_engine.h
typedef struct {
    char * text;      // transcribed text for this segment (malloc'd)
    float  t0_ms;     // segment start time in milliseconds
    float  t1_ms;     // segment end time in milliseconds
} sv_segment;

typedef struct {
    sv_segment * segments;  // array of segments
    int          count;     // number of segments
    char       * language;  // detected language
} sv_result;

// New function
sv_result sv_transcribe_segments(
    void * handle,
    const char * wav_path,
    const char * language,
    int n_threads,
    asr_progress_fn on_progress,
    void * progress_userdata);

// Free the result
void sv_free_result(sv_result result);
```

**Swift segment model:**

```swift
public struct SubtitleSegment: Sendable, Codable {
    public let text: String
    public let startMs: Float
    public let endMs: Float
}
```

---

## Implementation Units

### U1. Extend C API to support per-segment transcription

**Goal:** Add `sv_transcribe_segments()` function that returns text + timing for each VAD speech segment.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `Sources/CAsrEngine/include/asr_engine.h`
- Modify: `Sources/CAsrEngine/sense_voice_adapter.cpp`

**Approach:**
- Define `sv_segment` and `sv_result` structs in `asr_engine.h`
- Declare `sv_transcribe_segments()` and `sv_free_result()`
- In adapter: after VAD produces segments, branch on segment count:
  - **≤10 segments (default)**: iterate each segment individually — extract PCM samples, call `sense_voice_full_parallel()`, decode tokens to text, store `(text, t0_ms, t1_ms)`
  - **>10 segments (long audio)**: batch segments into ~30s windows with 200ms silence padding between adjacent segments; transcribe each batch as one ASR call; distribute batch output text back to individual segments proportionally by `segment_duration / batch_duration`
- Skip segments <400 samples (existing filter)
- `t0_ms = seg.t0 * 1000.0 / SENSE_VOICE_SAMPLE_RATE`, same for t1
- Allocate result array + per-segment text strings with `malloc`/`strdup`; `sv_free_result()` frees all

**Patterns to follow:**
- Existing `asr_progress_fn` callback pattern in `asr_engine.h`
- Existing progress callback bridge in adapter (`progress_bridge` struct)
- Existing `sv_load_model`/`sv_free` memory management convention

**Test scenarios:**
- Happy path: 16kHz mono WAV with 3 clear speech segments → returns 3 `sv_segment` entries with non-empty text and monotonically increasing times
- Edge case: silent WAV → returns `count=0`, no crash
- Edge case: single very long segment (30s+) → returns 1 segment with full text
- Error path: invalid WAV path → returns `segments=NULL`, `count=0`

**Verification:**
- `sv_transcribe_segments()` compiles and links against the ggml static libs
- Calling from a test harness produces correct segment count and plausible text per segment
- Existing `sv_transcribe()` function behavior is unchanged

---

### U2. Add SubtitleSegment model to VoiceGumServices

**Goal:** Define the `SubtitleSegment` struct and wire it into `TranscriptionResult` and `HistoryEntry`.

**Requirements:** R2, R5

**Dependencies:** None (can proceed in parallel with U1)

**Files:**
- Modify: `Sources/Services/Transcription/TranscriptionTypes.swift`

**Approach:**
- Add `SubtitleSegment` struct conforming to `Sendable, Codable` with `text: String`, `startMs: Float`, `endMs: Float`
- Add `public let segments: [SubtitleSegment]?` to `TranscriptionResult` (default `nil` in init)
- Add `public let segments: [SubtitleSegment]?` to `HistoryEntry` (default `nil` in init)
- `Codable` with optional key → old JSON without `segments` key decodes to `nil` automatically
- Mark fields as `let` (value-type immutability, consistent with existing fields)

**Patterns to follow:**
- Existing `TranscriptionResult` init pattern (all fields with defaults)
- Existing `HistoryEntry` init pattern (positional + defaults for optionals)
- Existing `Sendable, Codable` conformance pattern

**Test scenarios:**
- Happy path: `SubtitleSegment(text: "你好", startMs: 0.0, endMs: 1500.0)` round-trips through `JSONEncoder`/`JSONDecoder`
- Edge case: old history.json without `segments` key → `HistoryEntry.segments == nil` after decode
- Edge case: `TranscriptionResult` without segments → `segments == nil`

**Verification:**
- Project compiles against `VoiceGumServices` target
- Existing tests (if any) continue to pass — no breakage to existing Codable behavior

---

### U3. Update GGMLTranscriptionService to capture segment data

**Goal:** Call the new `sv_transcribe_segments()` and populate `TranscriptionResult.segments`.

**Requirements:** R2

**Dependencies:** U1, U2

**Files:**
- Modify: `Sources/Services/Transcription/GGMLTranscriptionService.swift`

**Approach:**
- Add a private method or inline logic to call `sv_transcribe_segments()` instead of `sv_transcribe()` when the engine is SenseVoice
- Declare `sv_transcribe_segments` and `sv_free_result` as C function imports (same pattern as existing `sv_transcribe`)
- On success: iterate `sv_result.segments[0..count]`, create `[SubtitleSegment]` from each, wrap in `TranscriptionResult`
- On failure (NULL return): throw `TranscriptionError.transcriptionFailed`
- Keep existing `sv_transcribe()` path as fallback (only called if segments path is unavailable)
- Progress callback bridging: existing `(@convention(c) (Float, UnsafeMutableRawPointer?) -> Void)` pattern works for both functions
- Document that online API services (`OnlineAPITranscription`, `VolcanoEngineASR`) return `segments: nil` — no change needed to their code

**Patterns to follow:**
- Existing `withCheckedThrowingContinuation` for async bridge
- Existing `DispatchQueue.global()` off-main-thread dispatch pattern
- Existing defer-based temp file cleanup

**Test scenarios:**
- Happy path: transcribe audio with speech → `TranscriptionResult.segments` is non-nil with correct count
- Integration: each segment's `startMs < endMs`, time values are within audio duration
- Error path: C function returns NULL → throws `TranscriptionError.transcriptionFailed`

**Verification:**
- Full transcription flow produces `TranscriptionResult` with populated `segments` array
- Time values convert correctly from sample offsets to milliseconds

---

### U4. Implement SRT formatter

**Goal:** Pure function converting `[SubtitleSegment]` to valid SRT text per the standard format.

**Requirements:** R7, R8, R10

**Dependencies:** U2 (needs `SubtitleSegment` type)

**Files:**
- Create: `Sources/Services/Transcription/SubtitleFormatter.swift`

**Approach:**
- `public enum SubtitleFormatter` with static method: `static func toSRT(segments: [SubtitleSegment]) -> String`
- Merge pass: iterate segments; if `endMs - startMs < 300`, merge into previous segment (concatenate text, extend end time). Repeat until no merges remain.
- Split pass: for segments where `duration > 7000 || charCount > 84`, split at the nearest punctuation (。！？, .!?) or at the character midpoint if no punctuation found. Each split sub-segment gets proportional time.
- Format pass: iterate final segments, format as `{i}\n{HH:MM:SS,mmm} --> {HH:MM:SS,mmm}\n{text}\n\n`
- Time formatting helper: `func formatTime(ms: Float) -> String` → `String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)`
- Handle empty input: return `""` (no file written — caller checks)
- Handle single-segment: output one SRT entry

**Patterns to follow:**
- `AudioConverter` enum-with-static-methods pattern (no instance state needed)
- `TranscriptionTypes.swift` existing public struct conventions

**Test scenarios:**
- Happy path: 3 segments → 3 SRT entries with sequential indices and correct timecodes
- Edge case — merge: segment of 0.2s adjacent to 2s segment → merged into one entry
- Edge case — split: single 10s segment with 120 chars → split into 2 entries at comma
- Edge case — empty: `[]` → `""`
- Edge case — single: 1 segment → 1 SRT entry (no index conflict)
- Correctness: SRT output parses correctly with a standard SRT parser
- UTF-8: Chinese/Japanese/Korean characters in text → no garbled output

**Verification:**
- Unit-testable without any service dependencies
- Run `swift test` (if test target exists) or verify by calling from a Swift script
- Output passes manual inspection: open `.srt` in VLC with matching audio

---

### U5. Auto-generate SRT on transcription completion

**Goal:** When transcription completes with segment data, write SRT file to the result directory automatically.

**Requirements:** R3, F1

**Dependencies:** U3 (needs segments in TranscriptionResult), U4 (needs formatter)

**Files:**
- Modify: `Sources/Core/TranscriptionViewModel.swift`

**Approach:**
- In the completion path (after `saveResults()`), check `results.flatMap { $0.segments ?? [] }`
- If non-empty: call `SubtitleFormatter.toSRT(segments:)`, write to result directory
- Filename: source filename stem + `_` + ISO8601 timestamp + `.srt` (e.g., `meeting_20260611T143021.srt`)
- If empty segments: skip SRT generation (zero-segment case, online ASR)
- Write using `String.write(to:atomically:encoding:.utf8)` — same pattern as existing `saveResults()`
- Add `generateSubtitleFileName(sourceURL: URL) -> String` helper method

**Patterns to follow:**
- Existing `saveResults()` directory creation + file write pattern
- Existing `Result` directory path via `FileManager.default.urls(for:.applicationSupportDirectory,...)`

**Test scenarios:**
- Happy path: transcribe audio with 3 VAD segments → result directory contains `.srt` file alongside `.txt` files
- Edge case — overwrite: transcribe same file twice → two distinct `.srt` files with different timestamps
- Edge case — zero segments: VAD finds no speech → no `.srt` file created, no error surfaced
- Edge case — online ASR: segments is nil → no `.srt` file created, existing behavior unchanged

**Verification:**
- Run app, transcribe audio, check `~/Library/Application Support/VoiceGum/Result/` for `.srt` file
- SRT file opens correctly in VLC/IINA with the source audio

---

### U6. Update HistoryManager for segments persistence

**Goal:** Ensure `segments` field is preserved when HistoryEntry is mutated (updateRefinedText, updateSummary).

**Requirements:** R5, R9

**Dependencies:** U2

**Files:**
- Modify: `Sources/Services/History/HistoryManager.swift`

**Approach:**
- `updateRefinedText` and `updateSummary` reconstruct `HistoryEntry` via positional init — add `segments: entry.segments` to each reconstruction call
- If `HistoryEntry.init` has `segments` defaulting to `nil`, these call sites continue to compile — but explicitly passing `entry.segments` is safer and more explicit
- No changes to `add` or `delete` methods
- Verify `Codable` backward compatibility: decode old `history.json` without `segments` key → `segments` is `nil`

**Patterns to follow:**
- Existing `updateRefinedText` pattern: `let entry = entries[idx]; entries[idx] = HistoryEntry(id:..., sourceFileName:..., ..., refinedText: refinedText)`

**Test scenarios:**
- Happy path: add entry with segments → update refined text → entry still has segments data
- Edge case — old data: decode history.json from pre-feature version → all entries have `segments == nil`
- Edge case — round-trip: encode entry with segments → decode → segments intact

**Verification:**
- Existing history records survive app upgrade without crash or data loss
- Manual export from history uses the same timecodes as auto-generated SRT

---

### U7. Add manual export button to history view

**Goal:** Let users export SRT from previously transcribed recordings via NSSavePanel.

**Requirements:** R4, R6, F2

**Dependencies:** U4 (formatter), U6 (persisted segments)

**Files:**
- Modify: `Sources/Core/HistoryView.swift`
- Modify: `Sources/Core/TranscriptionViewModel.swift` (add export helper)

**Approach:**
- Add "Export Subtitles" button in `HistoryDetailView` toolbar area (next to existing Copy buttons)
- Button disabled when `entry.segments == nil` (old records, online ASR) — set `.disabled(entry.segments == nil)`
- Button action: call a new `exportSubtitles(entry:)` method on `TranscriptionViewModel`
- `exportSubtitles` method:
  1. Present `NSSavePanel` with `.srt` allowed content type and suggested filename
  2. On user confirm: format SRT from `entry.segments`, write to selected URL
  3. On cancel: no-op
  4. On write failure: show `NSAlert` with error description
- Use `@MainActor` for NSSavePanel presentation (must be on main thread)
- Suggested filename: `{sourceFileName stem}.srt`

**Patterns to follow:**
- `NSOpenPanel` pattern in `Sources/App/AppDelegate.swift` (line 67-74): `allowedContentTypes`, `beginSheetModal`, `completionHandler`
- Existing Copy button pattern in `HistoryDetailView` (line 89-98)

**Test scenarios:**
- Happy path: entry has segments → click Export → NSSavePanel opens → choose location → SRT file written, timecodes match auto-generated
- Edge case — disabled: entry without segments (old record) → Export button grayed out
- Error path — write failure: target directory not writable → NSAlert with error message, no crash
- Edge case — cancel: user opens NSSavePanel, clicks Cancel → no file written, no error

**Verification:**
- Export from history produces SRT file identical to auto-generated one (same timecodes, same text)

---

## System-Wide Impact

- **Interaction graph:** TranscriptionViewModel completion path gains an SRT write step after saveResults. HistoryDetailView gains one new button. C API surface gains one new function. No changes to MainView, MainView.body switch, or the state machine enum.
- **Error propagation:** SRT write failures in the auto-generation path are logged but do not fail the transcription — the user still gets text results. Manual export failures surface via NSAlert, not exceptions.
- **State lifecycle risks:** `HistoryEntry` is a value type reconstructed on mutation — the `segments` field must be explicitly carried forward in `updateRefinedText`/`updateSummary` (U6). Missing this would silently drop segment data.
- **API surface parity:** CLI module (`VoiceGumCLI`) depends on `VoiceGumServices` — the new `SubtitleSegment` type and `SubtitleFormatter` are available to it. The CLI does not auto-generate SRT (no UI layer), but could be extended later via a `--subtitle` flag.
- **Integration coverage:** `segments` flows from C → Swift → Codable → JSON → Codable → SRT. Each boundary is a potential data-loss point — test scenarios cover the full chain.
- **Unchanged invariants:** Existing `sv_transcribe()` C function is untouched. Online API transcription paths are untouched (return `segments: nil`). Existing history records are untouched (decode to `segments: nil`). The `TranscriptionState` enum is unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Per-segment ASR loses cross-segment encoder context, reducing accuracy near segment boundaries | VAD already cuts at natural silence boundaries where context is minimal. Evaluate with real multi-language audio post-implementation; word-level alignment deferred for v2. |
| Long audio (2h+) produces 100+ VAD segments — per-segment ASR would add significant latency | Batch threshold (10 segments) triggers 30s-window batching path, capping ASR calls to `ceil(total_seconds / 30)`. Text is distributed back to individual segments proportionally by duration. Short/medium audio stays on per-segment path for best text-to-timing accuracy. |
| Old app version fails to decode `segments` key in history.json | Swift `Codable` with `JSONDecoder` ignores unknown keys by default. Explicitly verify with a pre-feature build. Add a `## Assumptions` note in release if needed. |

---

## Documentation / Operational Notes

- No user-facing documentation changes required — the feature is self-discoverable (SRT appears in result directory; export button appears in history)
- AGENTS.md quirks section: note that SRT auto-generation only works with local GGML engine
- Model lifecycle: segment data is available only while the model is loaded. History persistence decouples export from model state.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-11-subtitle-export-requirements.md](../brainstorms/2026-06-11-subtitle-export-requirements.md)
- Related code: `Sources/CAsrEngine/sense_voice_adapter.cpp` (VAD pipeline, lines 99-195)
- Related code: `Sources/Services/Transcription/TranscriptionTypes.swift` (TranscriptionResult, HistoryEntry)
- Related code: `Sources/Services/Transcription/GGMLTranscriptionService.swift` (C API bridging)
- Related code: `Sources/Core/TranscriptionViewModel.swift` (completion path, saveResults)
- Related code: `Sources/Core/HistoryView.swift` (detail view layout)
- Related plan: `docs/plans/2026-05-14-003-feat-unified-ggml-asr-engine-plan.md` (unified C API)
