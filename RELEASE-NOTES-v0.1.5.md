# PhotoSnail v0.1.5

Hardening release. Live-reload for settings changes mid-batch, generalized priority management (now covers mlx-vlm / vLLM / LM Studio in addition to Ollama), and a deep round of internal cleanup driven by two code review passes. No breaking changes — drop-in replacement for v0.1.4.

## What's new

### Settings changes take effect on the next photo

Previously, changing the provider URL, API key, model, prompt, or sentinel in Settings during a batch didn't take effect until the worker fully stopped and was restarted. Pause + change + Resume kept using the old values — a real footgun if you noticed a typo in your endpoint mid-run.

The worker now re-reads its config on every iteration via a new `RunConfig` snapshot. Edits applied while the queue is paused land on the very next photo after Resume. Client and pipeline construction are cheap (no network, no allocation worth measuring against ~60 s of LLM inference), so this isn't a throughput hit.

### Lower LLM priority — generalized to all providers

The v0.1.2 "renice Ollama during batches" feature now covers the OpenAI-compatible providers too. A new `LLMPriorityManager` with `ProviderPreset` cases finds the right processes based on the active provider:

- **Ollama**: `pgrep -f ollama` (covers the daemon and transient runners).
- **OpenAI-compatible**: `pgrep -f 'mlx[_-]vlm'`, `vllm`, `LM Studio`, `lms server` — deliberately narrow so arbitrary Python processes aren't reniced.

A **Lower LLM priority during processing** toggle in the lower-left runner dock exposes the whole thing. Default on. Localized into all 8 languages. The original nice values are always restored on batch end (normal exit, pause, cancel, or crash).

### Provider-agnostic error taxonomy

`PhotoSnailError.ollamaRequestFailed` → `.llmRequestFailed`; `.ollamaResponseParseFailed` → `.llmResponseParseFailed`. Log output now identifies the backend that actually failed: `llmRequestFailed: openai-compatible HTTP 500: ...` instead of the misleading `ollamaRequestFailed: ...` when you were actually running mlx-vlm. Retry semantics are unchanged.

## Stability

### Settings save ordering

`applyConfigChange()` and the two toggle setters (`setAutoStartWhenLocked`, `setLowerLLMPriority`) now save to disk FIRST and mirror into engine state only on success. If `Settings.save()` throws (disk full, permission denied), the engine no longer silently shows the user's edits as if they were persisted — the UI stays aligned with what's on disk and the error surfaces.

### Pause state machine

Three fields (`isPausedFlag`, `stopAfterPhotoID`, `pauseContinuation`) and their ad-hoc boolean juggling are replaced by a single `PauseRequest` enum: `.none`, `.armed`, `.afterPhoto(id:)`. The intent is now explicit at every call site; the compiler enforces the state transitions; the continuation remains separate as the park mechanism.

### Queue claim performance

v3 → v4 schema migration adds a composite `idx_assets_claim ON assets(status, priority DESC)` index matching `claimNext()`'s `WHERE status='pending' ORDER BY priority DESC, rowid LIMIT 1` query. Negligible at 1k rows, material above 10k. Purely additive — existing queue DBs auto-migrate on first open with v0.1.5, no data touched.

## Internal refactors

These don't change behavior but make the codebase easier to keep healthy:

- **`PhotoSnailPhotos` target.** `PhotoLibrary.swift`, `PhotosScripter.swift`, `PhotoLibraryEnumerator.swift` used to be duplicated byte-for-byte across `PhotoSnailApp` and `PhotoSnailGUI`. They now live in a new shared library target. The CLI stays PhotoKit-free (`PhotoSnailCore` is unchanged). ~540 lines of copy-paste maintenance overhead removed.
- **Single LLM client factory.** `PhotoSnailCore.makeLLMClient(provider:ollama:openai:imageOptions:)` is now the only place the `switch LLMProvider` lives. `Settings.makeLLMClient`, `ProcessingEngine.makeCurrentClient`, and the detached worker's inline construction all route through it. Adding a third provider later touches one function.
- **Worker branch dedup.** The caption and translation branches shared ~35 lines of write-back plumbing and completion-UI code. Extracted into `performWriteBack(id:description:tags:sentinel:)` and `recordCompletion(description:tags:)`. Any future fix to the write-back flow lands in one place.
- **Settings v3 is one-way.** The encoder no longer mirrors `customPrompt` / `promptLanguage` / `sentinel` into top-level keys alongside `modelConfigs`. That mirror was a split-brain risk (a v0.1.3 reader editing a v0.1.4 file would update the mirror without touching `modelConfigs`). `modelConfigs` is now the single source of truth; the decoder still handles v1/v2 → v3 migration from legacy fields. Downgrading to v0.1.3 is explicitly not supported — back up `settings.json` before downgrading.
- **Swift 6 Sendable cleanup.** `OllamaClient.imageOptions` and `OpenAIClient.imageOptions` flipped from `var` to `let` (they're never mutated after init). Worker-task `MainActor.run { ... self?.xxx ... }` closures now use `[weak self] in; guard let self else { return }` consistently. `LockWatcher` observer callbacks use `MainActor.assumeIsolated` (the notification queue is already `.main`). Build is warning-free.

## Upgrading

Drop-in replacement. Queue DB auto-migrates v3 → v4 on first open (just adds an index — no data touched). Settings are unchanged.

## Internal notes

- New `RunConfig` struct in `Sources/PhotoSnailGUI/ProcessingEngine.swift` + `currentRunConfig()` accessor.
- `Sources/PhotoSnailCore/OllamaPriorityManager.swift` renamed internally to `LLMPriorityManager` (the file kept its original name to preserve git history).
- New `Sources/PhotoSnailPhotos/` target in `Package.swift`; the unified `PhotoLibraryEnumerator` takes a `log: @escaping (String) -> Void` closure.
- Two new localization keys (`setting.lower_llm_priority` and its `.help`) across all 8 languages.
- Schema version bumped to `4` in `AssetQueue.currentSchemaVersion`.
