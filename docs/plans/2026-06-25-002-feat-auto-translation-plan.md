---
title: feat: Add automatic subtitle translation via LLM
type: feat
status: active
date: 2026-06-25
origin: docs/brainstorms/2026-06-25-auto-translation-requirements.md
---

# feat: Add Automatic Subtitle Translation via LLM

## Summary

Add an independent translation post-processing step after subtitle generation: when the transcription language mismatches the configured target language, translate subtitle segments via the existing LLM client. Default bilingual output (original + translation in one SRT file), with configurable per-segment or batch translation modes, and optional language-based segment splitting for mixed-language audio.

---

## Problem Frame

VoiceGum currently outputs transcription results only in the original language. Users consuming non-native content must export SRT files and translate them externally. The existing LLM infrastructure already supports refine and summarize — translation is a natural extension that closes this gap without adding new service dependencies. See origin document.

---

## Requirements

- R1. Translation triggers only after successful transcription with subtitle segments; independent of refine/summarize pipeline (origin R1)
- R2. Language mismatch: SenseVoice uses detected language; online ASR uses configured source language. Trigger when source ≠ target (origin R2)
- R3. Skip translation when source == target language (origin R3)
- R4. Per-segment mode: each segment sent individually to LLM, preserving timeline (origin R4)
- R5. Batch mode: all segments merged, translated in one LLM call, parsed back to segments (origin R5)
- R6. Default per-segment mode (origin R6)
- R7. Translation preserves original timeline (origin R7)
- R8. Bilingual output (default): single SRT with original + translation per block. Translation-only: two separate SRT files (origin R8)
- R9. SRT auto-export follows existing `subtitleExportEnabled` preference (origin R9)
- R10. Language split: group segments by detected language into separate files (origin R10)
- R11. Language split requires SenseVoice per-segment detection; unavailable for online ASR (origin R11)
- R12. Reuse existing LLMClient infrastructure with new `translate` method (origin R12)
- R13. Independent translation system prompt, user-editable (origin R13)
- R14. Default prompt guides LLM to preserve conversational style, no extra commentary (origin R14)
- R15. General tab: translation toggle (default off), output mode (bilingual/translation-only, default bilingual), target language picker (default zh-CN), language split toggle (default off) (origin R15)
- R16. LLM tab: translation mode picker (per-segment/batch), translation prompt editor (origin R16)
- R17. Target language options: zh-CN, en, ja, ko (origin R17)
- R18. Translation results persisted in HistoryEntry (origin R18)
- R19. All translation preferences via AppPreferences/UserDefaults (origin R19)

**Origin actors:** A1 (User), A2 (LLM service)
**Origin flows:** F1 (per-segment translation), F2 (batch translation), F3 (user configuration)
**Origin acceptance examples:** AE1 (English→Chinese trigger), AE2 (same-language skip), AE3 (per-segment preserves timeline), AE4 (batch parse-back), AE5 (bilingual vs translation-only output), AE6 (export disabled), AE7 (online ASR no detection), AE8 (language split), AE9 (default bilingual)

---

## Scope Boundaries

- No real-time/streaming translation; post-processing only
- No simultaneous multi-target-language translation
- No non-LLM local translation
- No cross-pipeline integration with refine/summarize

### Deferred to Follow-Up Work

- Translation quality confidence scoring — future iteration
- Manual translation trigger from history detail view — future iteration

---

## Context & Research

### Relevant Code and Patterns

- `Sources/Services/LLM/LLMClient.swift` — `refine()` (L172) and `summarize()` (L183) are the direct pattern for `translate()`. Both route through private `send()` (L194). Provider-specific chat methods (`openaiChat` L205, `anthropicChat` L257, `ollamaChat` L313) handle the HTTP layer.
- `Sources/Core/TranscriptionViewModel.swift` — `startTranscription()` (L110) orchestrates the pipeline. The refine path (L211-254) shows the pattern: `Task.detached(priority: .userInitiated)` with `[weak self]`, iterate results, call LLM, update history, return to MainActor for UI state. Translation follows this exact pattern as a parallel `Task.detached`.
- `Sources/Services/Transcription/SubtitleFormatter.swift` — `toSRT()` (L7) is a pure static function with 3-stage pipeline (merge→split→format). A new `toSRTBilingual()` overload can reuse the first two stages and only differ in `formatSRT`.
- `Sources/Services/Transcription/TranscriptionTypes.swift` — `SubtitleSegment` (L3), `TranscriptionResult` (L15), `HistoryEntry` (L31), `TranscriptionState` (L90). All are value types (structs), Codable, Sendable.
- `Sources/Preferences/AppPreferences.swift` — Key pattern: `voicegum.llm.{name}`. Refine/summary toggles at L88-96, prompts at L129-145. Translation keys follow same namespace.
- `Sources/Core/SettingsView.swift` — `GeneralSettingsTab` (L169) and `LLMSettingsTab` (L366). Tab 2 Task Prompts section (L469-488) is the template for translation UI.
- `Sources/Services/History/HistoryManager.swift` — `updateRefinedText()` (L25) shows the read→modify→write pattern for updating a single HistoryEntry field.
- `Sources/Core/HistoryView.swift` — `HistoryDetailView` (L115) uses `sectionBlock()` helper for each display section. Translation gets its own section block.

### Institutional Learnings

- `docs/solutions/` directory does not exist — no prior institutional learnings to carry forward.
- `todo/002-pending-p2-duplicate-prompt-defaults.md` — LLMClient fallback prompts are unreachable because ViewModel always passes AppPreferences value. New `translate()` should skip the fallback and require a prompt parameter.
- `todo/004-pending-p3-duplicated-code.md` — Three chat methods are ~80% identical. New `translate()` adds no new chat method; it routes through existing `send()`.

---

## Key Technical Decisions

- **Translation as a separate `Task.detached` from refine**: Per origin requirement that translation and refine are independent paths. Both use the same `LLMClient` actor, which naturally serializes requests — no explicit coordination needed.
- **Batch mode segment delimiting**: Use `[SEGMENT N]` / `[/SEGMENT N]` markers in the LLM prompt. LLM returns translated text between markers. Parse back by matching marker indices. If parsing fails, fall back to treating the entire LLM response as the translated full text and surface a warning.
- **Online ASR no-segments path**: When `TranscriptionResult.segments` is nil, force batch mode with the full `text` field. Per-segment mode is not applicable.
- **Language split before translation**: Split segments by detected language first, then translate only the groups whose language differs from the target. This avoids translating already-target-language segments.
- **Bilingual SRT format**: Single file, each block as `{original}\n{translation}`. New `SubtitleFormatter.toSRTBilingual(original:translated:)` overload.
- **`translatedSegments` as a separate array** on `TranscriptionResult` and `HistoryEntry`, not a new field on `SubtitleSegment`. Keeps original segments unmodified and avoids breaking existing code that reads `segments`.

---

## Open Questions

### Resolved During Planning

- Translation runs before or after refine? → Independent path; both fire in parallel `Task.detached` blocks after transcription completes. Natural actor serialization means one runs first non-deterministically — acceptable per origin scope.
- Batch mode parsing failure strategy? → Fall back to full-text translation, log warning, surface in UI.

### Deferred to Implementation

- Exact batch mode prompt wording and segment marker format — tune during implementation based on LLM behavior
- Whether to show a "translating..." progress indicator in the UI (new `TranscriptionState.translating` case) — depends on perceived latency; add if translation takes >2s

---

## Implementation Units

### U1. Data Model Extensions

**Goal:** Add translation fields to data types and persistence layer.

**Requirements:** R7, R18

**Dependencies:** None

**Files:**
- Modify: `Sources/Services/Transcription/TranscriptionTypes.swift`
- Modify: `Sources/Services/History/HistoryManager.swift`

**Approach:**
- Add `public let translatedText: String?` and `public let translatedSegments: [SubtitleSegment]?` to `TranscriptionResult`, defaulting to nil
- Add same fields to `HistoryEntry`, defaulting to nil
- Add `updateTranslatedText(id:translatedText:translatedSegments:)` to `HistoryManager`, following the `updateRefinedText` pattern: read existing entry, reconstruct with new translation fields, write back

**Patterns to follow:**
- `HistoryManager.updateRefinedText()` (L25-35) — read→modify→write pattern
- `TranscriptionResult` existing optional fields (`segments`, `language`) — nil-default pattern

**Test scenarios:**
- Happy path: Create `TranscriptionResult` with translated fields populated → Codable round-trip preserves values
- Happy path: Call `updateTranslatedText` on existing history entry → entry's translatedText and translatedSegments updated, other fields unchanged
- Edge case: `TranscriptionResult` with nil translated fields → Codable round-trip preserves nil
- Edge case: `HistoryEntry` with nil translated fields → `updateTranslatedText` sets them correctly

**Verification:**
- `TranscriptionResult` and `HistoryEntry` encode/decode correctly with new optional fields
- `HistoryManager.updateTranslatedText` persists and reloads translation data correctly

---

### U2. Translation Preferences

**Goal:** Add all translation-related UserDefaults preferences.

**Requirements:** R6, R8, R13, R14, R15, R17, R19

**Dependencies:** None

**Files:**
- Modify: `Sources/Preferences/AppPreferences.swift`

**Approach:**
- Add key constants in `Keys` enum: `autoTranslateEnabled`, `translateTargetLanguage`, `translateOutputMode`, `translateMode`, `translatePrompt`, `languageSplitEnabled`
- Add computed properties following existing pattern (get/set with `UserDefaults.standard`):
  - `autoTranslateEnabled: Bool` — default `false`
  - `translateTargetLanguage: String` — default `"zh-CN"`
  - `translateOutputMode: TranslateOutputMode` — enum `.bilingual` (default) / `.translationOnly`
  - `translateMode: TranslateMode` — enum `.perSegment` (default) / `.batch`
  - `translatePrompt: String` — default prompt in Chinese
  - `languageSplitEnabled: Bool` — default `false`
- Add `defaultTranslatePrompt` static string: guides LLM to preserve conversational tone, output only translation, no extra commentary
- Add `TranslateOutputMode` and `TranslateMode` enums in `AppPreferences.swift` — `VoiceGumPreferences` has zero dependencies per module graph, so enums referenced by AppPreferences must live in the same module

**Patterns to follow:**
- `autoRefineEnabled` (L88-91) — Bool toggle pattern
- `refinePrompt` (L129-132) — String prompt with default pattern
- `LLMProvider` enum (in LLMClient.swift) — enum-in-UserDefaults pattern

**Test scenarios:**
- Happy path: Set each preference → read back returns set value
- Happy path: Fresh install (no UserDefaults) → all translation preferences return documented defaults
- Edge case: Upgrade from previous version (no translation keys in UserDefaults) → defaults apply correctly

**Verification:**
- All new preferences persist across app restarts
- Default prompt is valid and passes to LLM without error

---

### U3. LLMClient translate() Method

**Goal:** Add translation capability to the LLM client.

**Requirements:** R12, R13, R14

**Dependencies:** None

**Files:**
- Modify: `Sources/Services/LLM/LLMClient.swift`

**Approach:**
- Add `translate(text:targetLanguage:customPrompt:)` method following `refine()` pattern:
  - Signature: `public func translate(text: String, targetLanguage: String, customPrompt: String? = nil) async throws -> String`
  - Default system prompt when `customPrompt` is nil: professional translation assistant, preserve tone, output only translation
  - User prompt: `"Translate the following text to \(targetLanguage):\n\n\(text)"`
  - Route through existing private `send()` method — no new provider-specific code
- Do not add unreachable fallback prompts (learn from `todo/002`); the ViewModel always passes the configured prompt

**Patterns to follow:**
- `refine(text:customPrompt:)` (L172-181) — exact method shape to replicate
- `summarize(text:customPrompt:)` (L183-192) — same pattern

**Test scenarios:**
- Happy path: Call `translate(text: "Hello", targetLanguage: "Chinese", customPrompt: nil)` → returns translated text via configured LLM
- Happy path: Call with `customPrompt` → custom prompt used as system message
- Error path: LLMClient not configured → throws `notConfigured`
- Error path: LLM returns HTTP error → throws `requestFailed`

**Verification:**
- `translate()` produces correct translation via each provider (OpenAI, Anthropic, Ollama)
- Method signature and error handling match `refine()` convention

---

### U4. Settings UI

**Goal:** Add translation controls to General and LLM settings tabs.

**Requirements:** R15, R16, R17

**Dependencies:** U2

**Files:**
- Modify: `Sources/Core/SettingsView.swift`

**Approach:**
- **GeneralSettingsTab**: Add translation section below subtitle export toggle:
  - Toggle "自动翻译" bound to `autoTranslateEnabled`
  - When enabled, show: target language Picker (zh-CN/en/ja/ko), output mode Picker (双语/仅译文), language split Toggle (only visible when local ASR mode, matching subtitle export visibility pattern)
- **LLMSettingsTab**: Add translation section in Task Prompts area (after summary section):
  - Translation mode Picker (逐条/整批) bound to `translateMode`
  - `TextEditor` for translation prompt bound to `translatePrompt`, with placeholder showing default
- Language split toggle visibility: conditionally shown only when local ASR mode is selected, matching the existing pattern for subtitle export toggle (L197: `if preferences.isLocal`)

**Patterns to follow:**
- `GeneralSettingsTab` subtitle export toggle (L197-206) — toggle + conditional visibility pattern
- `LLMSettingsTab` refine prompt section (L471-478) — toggle + TextEditor pattern
- `AppPreferences.language` Picker (L174-182) — language selection pattern

**Test scenarios:**
- Happy path: Toggle translation on → target language picker and output mode appear
- Happy path: Change target language → preference persisted immediately
- Happy path: Edit translation prompt → preference persisted
- Edge case: Translation toggle off → dependent controls hidden
- Edge case: Online ASR mode → language split toggle hidden/greyed out
- Edge case: Switch to local ASR mode → language split toggle appears

**Verification:**
- All translation controls render and bind correctly
- Preferences persist across tab switches and app restart
- Language split toggle visibility correctly tracks ASR mode

---

### U5. Bilingual and Language-Split SRT Formatting

**Goal:** Extend SubtitleFormatter to support bilingual output and language-based segment splitting.

**Requirements:** R7, R8, R10, R11

**Dependencies:** U1

**Files:**
- Modify: `Sources/Services/Transcription/SubtitleFormatter.swift`

**Approach:**
- Add `toSRTBilingual(original: [SubtitleSegment], translated: [SubtitleSegment]) -> String`:
  - Validate both arrays have same count; if mismatched, fall back to generating two separate SRT files
  - Reuse `mergeShortSegments` and `smartSplit` on original segments
  - Apply same merge indices to translated segments
  - Format each block as `{original.text}\n{translated.text}`
- Add `splitByLanguage(_ segments: [SubtitleSegment]) -> [String: [SubtitleSegment]]`:
  - Group segments by detected language
  - Requires language metadata per segment — see technical design note below
- Add convenience `toSRTFile` variants that accept the new output modes

**Technical design:**
> Directional guidance, not implementation specification.

Language split requires per-segment language information. Current `SubtitleSegment` has no language field. Two options:
1. Add optional `language: String?` to `SubtitleSegment` — requires changes in GGMLTranscriptionService to propagate per-segment language from the C engine
2. Use the top-level `TranscriptionResult.language` and treat all segments as that language (no per-segment granularity)

Option 1 is the correct approach for true language split but requires C engine changes. If the C engine's `sv_transcribe_segments` already returns per-segment language info, use it. If not, scope down: language split groups by the result-level detected language only, which handles the single-language case but not true mixed-language audio. The plan defers this investigation to implementation.

**Patterns to follow:**
- `toSRT()` (L7-13) — existing 3-stage pipeline
- `formatTime()` (L16-23) — time formatting reuse

**Test scenarios:**
- Happy path: `toSRTBilingual` with 3 matching segment pairs → SRT with `原文\n译文` per block
- Edge case: Mismatched segment counts → generates two separate SRT files, logs warning
- Edge case: Empty segments array → returns empty string
- Happy path: `splitByLanguage` with mixed en/zh segments → two groups returned correctly
- Edge case: `splitByLanguage` with single language → one group with all segments
- Edge case: `splitByLanguage` with empty array → empty dictionary

**Verification:**
- Bilingual SRT plays correctly in video players
- Language split produces valid per-language SRT files
- Time codes preserved across all output modes

---

### U6. Translation Orchestration in ViewModel

**Goal:** Wire translation into the transcription completion pipeline.

**Requirements:** R1, R2, R3, R4, R5, R9, R11

**Dependencies:** U1, U2, U3, U5

**Files:**
- Modify: `Sources/Core/TranscriptionViewModel.swift`

**Approach:**
- After transcription completes and results are available (same location as refine trigger, L211), check if translation should run:
  1. `autoTranslateEnabled` is true
  2. LLM client is configured
  3. Source language ≠ target language (R2, R3)
- If conditions met, spawn a `Task.detached(priority: .userInitiated)` for translation (parallel to refine's Task.detached):
  - For each `TranscriptionResult`:
    - Determine source language: `result.language ?? AppPreferences.language`
    - If segments exist and mode is per-segment: iterate segments, call `LLMClient.shared.translate()` per segment, build `translatedSegments` array with original timestamps
    - If segments exist and mode is batch: join segment texts with `[SEGMENT N]` markers, call `LLMClient.shared.translate()` once, parse response back to segments, validate count matches
    - If no segments (online ASR): force batch mode on `result.text`
  - Build new `TranscriptionResult` with `translatedText` and `translatedSegments` populated
  - Call `HistoryManager.shared.updateTranslatedText()` to persist
  - Optionally update UI state (e.g., `state = .translating`)
- On completion: if `subtitleExportEnabled`, call SRT generation:
  - Bilingual mode: `SubtitleFormatter.toSRTBilingual(original:translated:)`
  - Translation-only mode: `SubtitleFormatter.toSRT(original)` + `SubtitleFormatter.toSRT(translated)`
  - If language split enabled: `SubtitleFormatter.splitByLanguage()` first, then format per language
- Translation failure: log error, leave translation fields nil, still export original SRT. Do not fail the overall transcription.

**Execution note:** Implement translation orchestration test-first — write a unit test that verifies the language mismatch check and the mode dispatch before wiring the full LLM calls.

**Patterns to follow:**
- `startTranscription()` refine path (L211-254) — `Task.detached` + `[weak self]` + `MainActor.run` for UI updates
- `generateSRTFile()` (L332-354) — file naming and Result directory path

**Test scenarios:**
- Happy path: Transcription completes, language mismatch, per-segment mode → each segment translated, translatedSegments populated with original timestamps
- Happy path: Transcription completes, language mismatch, batch mode → one LLM call, response parsed back to segments
- Happy path: Same language → translation skipped entirely
- Edge case: `segments` is nil → forced batch mode on full text
- Edge case: Translation LLM call fails → error logged, original SRT still exported, translation fields nil
- Edge case: Batch mode LLM returns unparseable text → fallback to full-text translation, warning surfaced
- Edge case: Language split enabled + SenseVoice → segments grouped by language, split files generated
- Edge case: Language split enabled + online ASR → split skipped, single file output
- Integration: Translation and refine both enabled → both Task.detached fire, actor serializes, both results land in history

**Verification:**
- End-to-end: transcribe English audio → translated Chinese SRT exports correctly
- Translation failure does not block original SRT or mark transcription as failed
- Translation result visible in history after completion

---

### U7. History UI — Translation Display

**Goal:** Display translation results in the history detail view.

**Requirements:** R18

**Dependencies:** U1

**Files:**
- Modify: `Sources/Core/HistoryView.swift`

**Approach:**
- In `HistoryDetailView`, add a new section block for translation after the summary section (or after refined text if no summary):
  - Title: "翻译 (目标语言)" e.g., "翻译 (中文)"
  - Show `entry.translatedText` if available
  - Use a distinct accent color (e.g., `.orange`) to differentiate from refine (`.blue`) and summary (`.green`)
- The section is conditionally rendered: only shown when `entry.translatedText != nil`

**Patterns to follow:**
- `sectionBlock(title:color:text:)` helper usage in `HistoryDetailView` (L180-203)
- Refined text section (L189-196) — conditional display + Divider pattern

**Test scenarios:**
- Happy path: History entry has translatedText → translation section visible with correct title and content
- Edge case: History entry has nil translatedText → translation section not rendered
- Edge case: History entry has both refinedText and translatedText → both sections shown in order: summary → translation → refined → original

**Verification:**
- Translation text displays correctly in history detail
- Section order is logical and visually distinct
- No UI regression for entries without translation

---

## System-Wide Impact

- **Interaction graph:** Translation runs in a `Task.detached` inside `TranscriptionViewModel`, consuming `LLMClient.shared` (actor). No new callbacks or observer relationships. SRT generation path gains bilingual and language-split branches.
- **Error propagation:** Translation errors are logged and swallowed — they do not propagate to the transcription result or UI error state. Original SRT export always proceeds regardless of translation outcome.
- **State lifecycle risks:** `HistoryEntry` value-type reconstruction in `updateTranslatedText` must preserve `segments` field (same risk as `updateRefinedText`). Translation `Task.detached` must capture `[weak self]` to avoid extending ViewModel lifetime.
- **API surface parity:** Translation output modes (bilingual/translation-only) affect both auto-export and manual export paths. Manual export from history should eventually support translation output — deferred to follow-up.
- **Integration coverage:** Key integration scenario is translation + refine both enabled — both spawn `Task.detached`, both call `LLMClient.shared` (actor serializes), both update the same `HistoryEntry`. Test that final entry has both `refinedText` and `translatedText` populated correctly.
- **Unchanged invariants:** Existing refine/summarize pipeline is untouched — no new state machine transitions, no changes to `TranscriptionService` protocol, no changes to ASR engine interfaces. `SubtitleFormatter.toSRT()` existing signature is unchanged; new methods are additive.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| LLM translation quality varies by provider and prompt | User-editable prompt; default prompt tuned for subtitle translation |
| Batch mode segment parsing unreliable | Fall back to full-text translation + warning; user can switch to per-segment mode |
| Per-segment mode is expensive (N LLM calls for N segments) | Documented in settings; user chooses mode; no hard limit enforced |
| Language split requires per-segment language info from C engine | Investigate during implementation; scope down to result-level language if C engine doesn't expose it |
| Translation + refine both updating same HistoryEntry | Actor serialization ensures non-overlapping writes; `updateTranslatedText` and `updateRefinedText` each read→modify→write independently; last write wins for non-overlapping fields |

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-25-auto-translation-requirements.md](../brainstorms/2026-06-25-auto-translation-requirements.md)
- Related code: `Sources/Services/LLM/LLMClient.swift` — `refine()` / `summarize()` pattern
- Related code: `Sources/Core/TranscriptionViewModel.swift` — pipeline orchestration
- Related code: `Sources/Services/Transcription/SubtitleFormatter.swift` — SRT formatting
- Related plan: `docs/plans/2026-06-11-001-feat-subtitle-export-plan.md` — subtitle export foundation
