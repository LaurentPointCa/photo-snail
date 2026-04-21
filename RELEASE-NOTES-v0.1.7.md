# PhotoSnail v0.1.7

Library-inspection release. A built-in **Tools** menu surfaces three diagnostics over already-processed photos, and the reprocessing path has been hardened so the accumulation bug those tools were written to clean up can't come back. Plus a Pause vs Stop split with intent-aware lock-watcher semantics. No breaking changes — drop-in replacement for v0.1.6.

## What's new

### Tools menu (GUI) + CLI diagnostics

Three new non-modal tool windows under a top-level **Tools** menu, plus matching `photo-snail-app` flags for scripted / headless use. Each iterates every asset the queue marks `done`, reads its Photos.app description via AppleScript, and streams findings as it goes — no up-front wait for the full library scan.

- **Scan multi-segment descriptions** (`--scan-multi`): read-only. Finds assets whose description contains 2+ PhotoSnail payloads (≥2 `ai:…-v<N>` sentinels or ≥2 `\n\n---\n\n` separators). These are leftover from pre-v0.1.7 reprocessing that appended rather than replaced.
- **Clean multi-segment descriptions** (`--clean-multi`, with `--apply`): dry-run by default. For each accumulated row, collapses it down to a single payload — keeps the user's prefix (text before the first sentinel segment), the **latest** PhotoSnail segment only, and any user suffix (text after the last sentinel segment). Middle PhotoSnail segments and inter-segment noise are discarded. Idempotent: re-running on already-cleaned rows is a no-op. Verified on the author's 4k-photo library: 14 collapse candidates, 23,127 → 5,426 bytes (76.5% reduction), largest per-asset reduction 1,892 bytes on a 5-segment pileup.
- **Scan preserved original descriptions** (`--scan-preserved`): read-only. Lists assets where a user-authored description existed *before* PhotoSnail touched them and was preserved before our payload via the separator. Handy for auditing custom metadata (Stable Diffusion prompts, manual notes, prior captions).

Each row in the GUI tool windows has a **Show in library** button (and a right-click *Show in PhotoSnail library* menu item) that raises the main library window, resets filters, selects the asset, and centers it in the grid so you can inspect or act on it immediately.

### Pause vs Stop split

The primary runner dock now separates two distinct intents instead of collapsing them into one ambiguous "Pause."

- **Pause** (soft): yields to the lock watcher. If *Auto-start when Mac is locked* is on, a user-paused batch will auto-resume on the next screen lock. Previously the watcher only auto-*started* from idle — paused batches stayed paused through subsequent locks even though the toggle promise suggested otherwise.
- **Stop** (hard): the batch transitions to a new `.stopped` engine state, the worker exits cleanly at its park checkpoint, and the lock watcher skips `.stopped` unconditionally. Start brings it back on demand.

The primary button's old disabled "Waiting for lock…" label is gone. In idle/finished states, an always-enabled **Start** button is now paired with a `LockArmedChip` announcing "Auto-starts when Mac locks" (or "Auto-resumes when Mac locks" when paused) — the armed-intent is surfaced without disabling Start. Running and Paused states gain a secondary **Stop** button alongside Pause/Resume. 48 new strings across all 8 languages (`button.stop`, `status.stopped`, `chip.auto_start_armed`, `chip.auto_resume_armed`, and their helpers).

### User-prefix preservation across reprocessing

Reprocessing a photo whose description already carried a PhotoSnail payload used to destroy any user-authored text that had been preserved before it. `formatDescription`'s old rule was "if the existing text contains *any* sentinel, overwrite the whole thing" — correct for the common case, wrong when the user had text before `\n\n---\n\n` from an earlier preservation pass.

The new `Pipeline.splitExistingDescription(_:)` walks segments split on `\n\n---\n\n` and finds the **last** segment containing a PhotoSnail sentinel. Everything before that segment is the user's prefix (kept verbatim); the last PhotoSnail segment onward is ours (replaced by the fresh payload). Covers reprocessing, sentinel version bumps, prompt edits, provider switches, and re-translations — the user's original text survives all of them.

The snapshot-column alternative was considered and rejected: the user may edit their prefix after our first touch, and we want those live edits to survive instead of being overwritten by a frozen first-touch snapshot.

7 new pipeline tests + 4 direct splitter tests cover the full matrix: pure-ours overwrite, reprocess preservation, 3-touch no-accumulation, user-deleted-sentinel treated as fresh text, multi-separator prefixes survive intact.

### Broadened sentinel regex

Real-world finding during the 2026-04-20 library scan: 14 assets had accumulated 2–5 PhotoSnail payloads in their descriptions despite the write-back logic. Root cause: their sentinels contained an underscore (`ai:qwen36_4b-v20`) set manually via the GUI custom-sentinel field. The old regex `[a-z0-9]+(-[a-z0-9]+)*-v[0-9]+` didn't match, so the splitter treated each prior payload as user text and appended a fresh copy on every reprocess.

The shared `Sentinel.sentinelPattern = "ai:[A-Za-z0-9._-]+-v[0-9]+"` now accepts underscores, dots, and uppercase in the family portion. The `ai:` prefix stays lowercase-only and the `-v<digits>` anchor stays strict, so false positives on natural prose remain extremely unlikely. Both `Sentinel.containsAnySentinel` and all three Tools/CLI diagnostics use the same constant, so detection can't drift from write-back.

### Provider-aware preflight

The startup preflight sheet no longer shows Ollama-specific copy and fix commands when the active provider is OpenAI-compatible. `PreflightSheet` branches on `LLMProvider`: Ollama keeps its canonical `brew install` / `ollama pull` / one-click **Start Ollama** button; OpenAI-compatible gets guidance bullets for mlx-vlm, LM Studio, and vLLM (no single CLI is prescribed because the ecosystem doesn't have one). The displayed URL now comes from the correct provider's connection block.

`applyConfigChange()` now re-runs preflight after any provider / URL / model / API-key change, so stale failure sheets can't linger after a switch — preflight resets to `.checking` first, then transitions cleanly to `.ok` or re-presents with fresh copy. 10 new localization keys (`preflight.*_openai`) across all 8 languages.

### Status-bar tail refreshes after preflight retry

The window-wide LLM status bar (added in v0.1.6) now shows preflight activity in its live tail: a preflight begin event marks the pill as checking, the end event flips it to Connected on success and surfaces the error otherwise. Previously the tail only updated on `listModels` / `generateCaption` / `generateText`, so a successful preflight retry didn't visibly refresh the bar until the next real API call.

### About panel restoration

The About panel regained the human-readable build-stamp line (`Build 2026-04-20 15:17:03`) as a small tertiary entry below the version. `bundle-gui.sh` was already writing `PhotoSnailBuildDate` into `Info.plist`; the credits view now reads it back.

## Stability

### Splitter test coverage

`Tests/PhotoSnailCoreTests` gained 11 new tests around `splitExistingDescription` + `formatDescription` reprocess behavior, plus 7 new tests around `collapseMultiSegment`. The test named `testExistingUserTextPlusOurs_stillPreservedByContainsCheck` — which had been documenting the buggy overwrite behavior as "working as designed" — was updated to assert the correct preservation semantics.

### Reveal routing uses the library's single source of truth

`ToolsRouter.pendingReveal` drives the library window's existing reveal code path (reset filter to All, clear search and tag filters, select the asset, enable scroll-on-selection so the grid centers). No new code paths — the same mechanism the Log window's "Show in library" link already used.

## Upgrading

Drop-in replacement. No schema changes, no settings migration. Existing sentinels continue to work; custom underscore/dot/uppercase sentinels are now recognized retroactively.

If your library was processed before v0.1.7 and reprocessed at least once since, run **Tools → Scan multi-segment descriptions** to see if you have any accumulated descriptions, then **Clean multi-segment descriptions** (dry-run) to preview the collapse, then enable **Apply changes** and re-run to rewrite them. All three tools are idempotent — re-running after a clean pass finds nothing.

## Internal notes

- New `Sources/PhotoSnailGUI/Tools/` directory: `ToolsRouter.swift` (reveal signal + main-window raise), `ToolsEngine.swift` (async scan / clean functions callable from GUI or CLI, cancellable via `Task`), `ToolsWindow.swift` (generic SwiftUI view driven by a `ToolMode` enum — one codebase for all three tools).
- New `Pipeline.splitExistingDescription(_:)` and `Pipeline.collapseMultiSegment(_:)` helpers in `PhotoSnailCore`. `formatDescription` now routes through the splitter.
- New engine state `EngineState.stopped` and `stopIntent` flag in `ProcessingEngine`. `handleScreenLocked` short-circuits on `.stopped`, auto-resumes from `.paused` when the toggle is on, auto-starts from `.idle` / `.finished` as before.
- `PreflightSheet` now takes a `provider: LLMProvider` initializer argument + a `k(_:)` key-routing helper that appends `_openai` to relevant string keys.
- `Sentinel.sentinelPattern` is the single source of truth for sentinel regex matching — used by `containsAnySentinel`, the splitter, the collapse helper, and all three scan tools. Any future sentinel format change lands in one constant.
