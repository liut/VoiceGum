---
title: feat: Replace hardcoded ASR progress jumps with stage-gated callbacks and smooth interpolation
type: feat
status: completed
date: 2026-05-15
---

# feat: ASR Progress Smooth Interpolation

## Summary

Replace the three hardcoded progress jumps (0→10%→90%→100%) in the C++ adapter with real stage-gated callbacks from the SenseVoice engine's three processing stages (feature extraction, encode, decode), and add Swift-side time-based smooth interpolation on the main actor so the progress bar advances continuously and self-corrects when each real anchor arrives.

---

## Problem Frame

The current progress display jumps 0%→10% instantly after WAV loading, then stalls for the entire duration of `sense_voice_full_parallel` (a blocking call with no internal progress reporting), then jumps 90%→100% instantly. The user sees a progress bar that freezes for long periods and then completes abruptly — it feels fake and provides no useful information about actual processing state. The `progress_callback` field already exists in `sense_voice_full_params` but is never invoked by any code path.

---

## Requirements

- R1. Progress advances continuously during transcription — no visible stalls or frozen periods
- R2. Progress is anchored to real processing stages — when feature extraction finishes, progress reflects that milestone
- R3. Progress never decreases or jumps backward
- R4. Final 100% is only shown when text extraction is complete (the existing `on_progress(1.0f)` invariant)
- R5. The C API (`asr_progress_fn` signature in `asr_engine.h`) remains unchanged — no downstream consumers break
- R6. Only GGML/SenseVoice local ASR is affected; online API paths are unchanged

---

## Scope Boundaries

- Deeper ggml-level progress (per-token, per-layer) — CTC decoder is single-pass graph compute, no token loop to hook
- VAD-based segment processing for finer progress granularity — major architectural change
- Progress for online API transcription services (no progress data available from their protocols)
- UI redesign beyond progress smoothness

---

## Context & Research

### Relevant Code and Patterns

| File | Role |
|------|------|
| `Sources/CAsrEngine/sense_voice_adapter.cpp` | Hardcoded progress at lines 79/87/97; must be replaced |
| `Sources/CAsrEngine/sense-voice.cc:727-778` | `sense_voice_full_with_state` — three processing stages, no progress callbacks |
| `Sources/CAsrEngine/include/asr_engine.h:15` | `asr_progress_fn(float pct, void*)` — C API callback signature |
| `Sources/CAsrEngine/private_headers/common.h:427-429` | `sense_voice_progress_callback(ctx, state, int progress, void*)` — unused richer callback |
| `Sources/CAsrEngine/private_headers/common.h:437-467` | `sense_voice_full_params` — contains unused `progress_callback` field |
| `Sources/CAsrEngine/common.cc:43-73` | `sense_voice_full_default_params` — initializes `progress_callback = nullptr` |
| `Sources/Services/Transcription/GGMLTranscriptionService.swift:95-101` | C callback bridge pattern: `Unmanaged` + `@convention(c)` + `DispatchQueue.main.async` |
| `Sources/Core/TranscriptionViewModel.swift:130` | `captureDuration()` — audio duration already available before transcription |
| `Sources/Core/TranscriptionViewModel.swift:156-161` | `onProgress` wiring — sets `state = .transcribing(progress:)` |
| `Sources/Core/StateViews.swift:63-100` | `TranscriptionProgressView` — displays `ProgressView(value:)` + percentage text |
| `Sources/Services/Audio/AudioConverter.swift:57-91` | WAV header writer: 16kHz mono 16-bit PCM |
| `Sources/Services/Transcription/VolcanoEngineASR.swift:72` | Duration from PCM: `pcmData.count / 32000.0` |

### Institutional Learnings

- **C callback bridge pattern** is well-established: `Unmanaged.passUnretained(self).toOpaque()` → `@convention(c)` closure → `fromOpaque().takeUnretainedValue()` → `DispatchQueue.main.async`
- **SenseVoice RTF ~0.01** on Apple Silicon (benchmark: 245s audio processed in ~5.5s). A conservative RTF estimate of 0.05 gives safe headroom for time-based interpolation.
- **ggml Metal exclusivity**: only one Metal backend per process. No new Metal consumers.
- **Thread safety**: `GGMLTranscriptionService` uses `NSLock` for mutable state. The `onProgress` callback dispatches to `DispatchQueue.main.async`.
- **Model lifecycle**: `unload()` guards `isTranscribing` under lock. Any new code must not hold locks across async boundaries.

---

## Key Technical Decisions

- **Wire existing `progress_callback`, don't add new API surface.** The `sense_voice_full_params.progress_callback` field is defined but dead code. Wiring it avoids changing the C API contract (`asr_progress_fn` stays the same).
- **Bridge callback signatures in the adapter, not in the engine.** The adapter (`sense_voice_adapter.cpp`) converts the rich `sense_voice_progress_callback(int)` to the simple `asr_progress_fn(float)`. The engine only calls the rich callback — it doesn't know about the C API.
- **Time-based interpolation in ViewModel, not in service.** The service layer stays focused on forwarding raw callbacks. The ViewModel owns the UI state, audio duration, and display timer — interpolation is a presentation concern.
- **Progress values as percentage ints (15, 50, 95).** The `sense_voice_progress_callback` takes `int progress`. Using percentage values (0-100) is the natural fit — the bridge divides by 100.0 to produce the `float` the C API expects.
- **Conservative RTF default of 0.05.** Actual SenseVoice RTF is ~0.01, but a conservative estimate means the bar advances slightly slower than reality. Real callbacks will snap it forward, so underestimation is safe — the bar never waits at a value beyond where the engine actually is.

---

## Implementation Units

### U1. C++ engine: Invoke progress_callback at processing stages

**Goal:** Add `progress_callback` invocations in `sense_voice_full_with_state` so the engine reports progress after each of its three internal stages.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Modify: `Sources/CAsrEngine/sense-voice.cc`

**Approach:**
- After feature extraction (line 736): if `params.progress_callback != nullptr`, call with `progress = 15`
- After encode (line 765): if callback set, call with `progress = 50`
- After decode (line 770): if callback set, call with `progress = 95`
- Pass `ctx`, `state`, and `params.progress_callback_user_data` through to each call
- Stage weights reflect typical timing proportions: feature extraction is fast (~15%), encode medium (~35%), decode longest (~45%)

**Patterns to follow:**
- Existing `SENSE_VOICE_LOG_DEBUG` calls in the same function — same conditional style

**Test scenarios:**
- Happy path: Callback set → three invocations fire at correct stages → progress values are 15, 50, 95 in order
- Edge case: Callback is nullptr → no calls, no crash, function behaves identically to current
- Edge case: Feature extraction fails (n_samples ≤ 0) → callback not invoked, encode/decode still proceed

**Verification:**
- Build passes with `swift build -c release`
- Existing transcription still produces correct results (no regression in output text)

---

### U2. C++ adapter: Bridge progress_callback to C API and remove hardcoded jumps

**Goal:** Set up `wparams.progress_callback` in `sv_transcribe` so the engine's stage callbacks flow through to the C API's `on_progress`. Remove the now-redundant hardcoded `on_progress(0.1f)` and `on_progress(0.9f)` calls.

**Requirements:** R2, R5

**Dependencies:** U1 (callback must be invoked by engine)

**Files:**
- Modify: `Sources/CAsrEngine/sense_voice_adapter.cpp`

**Approach:**
- Define a file-local struct holding the C API callback + userdata:
  ```cpp
  struct progress_bridge { asr_progress_fn fn; void *data; };
  ```
- Define a static bridge function matching `sense_voice_progress_callback` that converts `int progress` → `float pct = progress / 100.0f` and calls `bridge->fn(pct, bridge->data)`
- In `sv_transcribe`, if `on_progress` is set, create the bridge struct on the stack and set `wparams.progress_callback` and `wparams.progress_callback_user_data`; if `on_progress` is null, leave `progress_callback` at its default `nullptr`
- Remove the `on_progress(0.1f)` call at line 79 and `on_progress(0.9f)` at line 87
- Keep `on_progress(1.0f)` at line 97 as the final "done" signal (outside the engine's scope)

**Patterns to follow:**
- The existing `sense_voice_wrapper` struct in the same file — same pattern: file-local struct for context

**Test scenarios:**
- Happy path: Transcription runs → Swift receives callbacks at ~0.15, ~0.50, ~0.95, 1.0
- Edge case: Engine callbacks fire out of order (shouldn't happen but defensively: bridge just forwards whatever it gets)
- Regression: Existing callers of `sv_transcribe` that pass `on_progress = nullptr` → no crash, `progress_callback` is not set either

**Verification:**
- Build passes
- Log the callback values from Swift side to confirm sequence: 0.15 → 0.50 → 0.95 → 1.0

---

### U3. Swift ViewModel: Add time-based smooth interpolation with Timer

**Goal:** Replace the raw jumpy progress display with a continuously advancing progress bar. A `Timer` on the main actor advances `displayProgress` toward `targetProgress` using audio-duration-based time estimation. When real C++ callbacks update `targetProgress`, the display smoothly catches up.

**Requirements:** R1, R3, R4, R6

**Dependencies:** U2 (real stage callbacks must arrive from C++)

**Files:**
- Modify: `Sources/Core/TranscriptionViewModel.swift`

**Approach:**
- Add two new private properties:
  - `targetProgress: Double` — the latest value from the C++ callback (initialized to 0)
  - `displayTimer: Timer?` — the interpolation timer
- When transcription starts (`.transcribing(progress: 0, ...)` is set):
  - Start a `Timer.scheduledTimer` with interval ~0.1s on `.main`
  - Use the already-captured audio duration (from `captureDuration()`) and a conservative RTF of 0.05 to compute `estimatedTotalSeconds = max(duration * 0.05, 1.0)`
- Each timer tick:
  - Compute `elapsedRatio = elapsed / estimatedTotalSeconds` (clamped to 0.99)
  - Compute `smoothedProgress = max(displayProgress + step, elapsedRatio)` where `step` is a small per-tick increment
  - `displayProgress = min(smoothedProgress, targetProgress + 0.03, 0.99)` — the +0.03 margin lets the bar run slightly ahead of the last anchor so it doesn't stall, but the 0.99 cap prevents reaching 100% before the real final callback
  - Update `state = .transcribing(progress: displayProgress, ...)`
- When `onProgress` fires with a new callback value:
  - Update `targetProgress = max(targetProgress, newValue)` (never decrease)
  - If `newValue >= 1.0`: invalidate timer, set `displayProgress = 1.0`
- Invalidate timer on: transcription completion, failure, cancellation, or ViewModel deinit
- Skip timer entirely when `duration` is nil (unknown audio length) — fall back to raw callback values

**Execution note:** Implement the timer interpolation first with a fixed RTF; tune the RTF and smoothing parameters during implementation by testing with various audio lengths.

**Patterns to follow:**
- `GGMLTranscriptionService.scheduleUnload(after:)` — uses `DispatchWorkItem` + `DispatchQueue.main.asyncAfter` (one-shot dispatch on main queue); U3 uses `Timer.scheduledTimer` (repeating) but shares the `.main` run loop target
- Existing `@Published var state` + `DispatchQueue.main.async` in `onProgress` wiring

**Test scenarios:**
- Happy path: 60s audio → timer starts → bar advances smoothly → callbacks at 0.15/0.50/0.95 correct the estimate → 1.0 arrives → bar completes
- Happy path: Very short audio (5s) → timer runs briefly → callbacks arrive quickly → bar completes
- Edge case: `duration` is nil → timer skipped → raw callback values used (no interpolation)
- Edge case: Callback arrives while timer is mid-tick → `targetProgress` updated, next tick uses new target
- Error path: Transcription fails → timer invalidated, no stale updates
- Error path: ViewModel deallocated during transcription → timer invalidated by deinit

**Verification:**
- Play a 30s audio file, observe the progress bar: it should advance continuously from 0% to ~99%, never freeze for more than ~0.5s, and snap to 100% only when transcription actually completes
- Cancel mid-transcription: progress bar stops updating immediately

---

## System-Wide Impact

- **Interaction graph:** `sense_voice_full_with_state` → `progress_callback` → adapter bridge → `asr_progress_fn` → `GGMLTranscriptionService.onProgress` (main thread) → `TranscriptionViewModel.targetProgress` → `Timer` → `state.transcribing(progress:)` → `MainView` → `TranscriptionProgressView`
- **Error propagation:** If any C++ stage fails (returns non-zero), `sv_transcribe` returns `nullptr` and Swift throws `transcriptionFailed` — timer is invalidated in the catch path. No partial progress callbacks are emitted for failed stages (the function returns early).
- **State lifecycle risks:** Timer must be invalidated in all exit paths (success, failure, cancel, deinit). A leaked timer would continue updating `@Published state` after the ViewModel is no longer observed — use `[weak self]` in the timer block.
- **API surface parity:** `TranscriptionService` protocol has no `onProgress` — only `GGMLTranscriptionService` (concrete type) has it. The ViewModel already casts to the concrete type (line 155). No protocol change needed.
- **Integration coverage:** The end-to-end chain from C++ callback → main-thread dispatch → ViewModel state → SwiftUI rendering must be verified with a real transcription, not just unit tests.
- **Unchanged invariants:** `asr_progress_fn` typedef unchanged. `GGMLTranscriptionService.onProgress` closure type unchanged. `TranscriptionState.transcribing(progress:currentFile:totalFiles:)` unchanged. Online API transcription paths untouched.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Stage weight estimates (15/50/95) may not match actual timing proportions across different audio lengths | Weights are anchors, not hard splits — time-based interpolation fills the gaps. The real callbacks correct the estimate regardless of weight values. Tune if user reports visible snapping. |
| RTF estimate of 0.05 may be too slow for very short audio (bar at 80% when transcription completes) | The final 1.0 callback snaps the bar to 100%. For short audio (< 10s), the entire transcription takes < 0.5s — the bar is inherently transient and exact interpolation matters less. |
| Timer-based interpolation adds ~0.1s latency to progress updates | The timer interval is 0.1s — each tick dispatches to the main actor. This is imperceptible for a progress bar. Using a faster interval (0.05s) would add CPU overhead with no visible benefit. |

---

## Documentation / Operational Notes

- AGENTS.md "Known Quirks" section: no update needed — the ggml Metal exclusivity note remains accurate
- No new UserDefaults keys, no new Keychain entries, no new file paths
- The progress bar behavior change is visible to users but requires no configuration or migration

---

## Sources & References

- SenseVoice benchmark: `docs/brainstorms/2026-05-14-asr-performance-benchmark-results.md` (RTF ~0.01)
- Prior related plan (not implemented): `docs/plans/2026-05-14-002-fix-progress-animation-and-window-resize-plan.md`
- C callback bridge pattern: `Sources/Services/Transcription/GGMLTranscriptionService.swift:93-101`
- Audio duration capture: `Sources/Core/TranscriptionViewModel.swift:346-355`
