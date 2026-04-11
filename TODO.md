# Photo-Tag — Project Plan

_Local-first hybrid pipeline for tagging and describing the macOS Photos library using Apple Vision + Gemma4 (via Ollama). Quality is the priority; processing time is acceptable._

_Created: 2026-04-07_

---

## Goal

For every photo in the user's Photos library, produce:
1. A 2–3 sentence natural-language **description**
2. A set of 5–15 lowercase **tags**

Write both back to the asset's Photos metadata so they appear in Photos search and sync via iCloud.

## Constraints & priorities (in order)

1. **Quality** — accurate, specific descriptions (named objects, brands, gear types where visible)
2. **Privacy** — fully local pipeline; no cloud APIs in the default path
3. **Resilience** — multi-day batch must survive sleep/wake/restart
4. **Idempotency** — re-running on a processed library is a no-op
5. **Speed** — last priority; ~70 s/photo on `gemma4:31b` is acceptable

## Architecture (v3 — locked 2026-04-07)

The pipeline runs Vision as a **side channel**: it captures structured signals (OCR, animal/face counts) and is used for tag-rescue, but Vision findings are NOT injected into the LLM prompt. The repeatability test (2026-04-07) showed the in-prompt hybrid was paying ~2× generation cost for marginal quality gains; the side-channel design gives full quality at bare-prompt speed.

```
For each PHAsset:
  1. Skip if asset already has sentinel keyword "ai:gemma4-v1"
  2. Export downsized JPEG (1024 px long edge, 80% quality) via PHImageManager
  3. Apple Vision pre-pass (~400-1000 ms) — runs in parallel, NOT injected into the LLM prompt:
       - VNClassifyImageRequest        → seed labels + confidences (structured metadata only)
       - VNRecognizeAnimalsRequest     → animal counts + bboxes (structured metadata)
       - VNDetectFaceRectanglesRequest → face count + bboxes (structured metadata)
       - VNRecognizeTextRequest        → OCR text (used for tag rescue + structured metadata)
  4. Call gemma4:31b via Ollama HTTP API with the bare prompt + downsized image
  5. Parse DESCRIPTION and TAGS from the LLM response
  6. Merge tag set:
       - Start with LLM tags (authoritative)
       - Cross-check rescue: add OCR tokens that the LLM also mentioned anywhere in its response
       - Vision classification labels are NOT merged (they leak generic "structure"/"machine"/"mammal" noise)
  7. Write back to PHAsset:
       - description → IPTC caption / asset title
       - tags        → merged tag set
       - structured  → animal_count, face_count, ocr_text (custom asset properties or sidecar)
       - sentinel    → "ai:gemma4-v1"
  8. Persist progress to a SQLite queue (asset id, status, error, attempts)
```

**Key design rules (validated 2026-04-07):**
- Don't inject Vision findings into the LLM prompt — costs ~2× gen time for marginal quality gain
- Don't drop Vision entirely — OCR rescue + structured metadata are nearly free (~1 s/photo)
- Don't merge Vision classification labels into the tag set — they leak generic terms
- Always run with downsize (1024 px long edge, JPEG q=0.8) — ~3× speedup, no quality loss

## Phases

### Phase A — Project plan & repo setup ✅
- [x] Decide on architecture (Vision + gemma4:31b hybrid, fully local)
- [x] Document plan in this TODO
- [x] Reference this file from `~/claude/tasks/todo.md`

### Phase B — Hybrid pipeline scaffold (CLI, no PhotoKit yet) ✅
- [x] Swift Package Manager project structure (`Package.swift`, two targets)
- [x] `PhotoSnailCore` library:
  - [x] `Models.swift` — `VisionFindings`, `CaptionResult`, `PipelineResult`, `PromptStyle`
  - [x] `VisionAnalyzer.swift` — four Vision requests, EXIF orientation via CGImageSource
  - [x] `OllamaClient.swift` — async HTTP client, integrated `ImageDownsizer` (1024 px)
  - [x] `PromptBuilder.swift` — both `bare()` and `build(findings:)` (hybrid)
  - [x] `CaptionParser.swift` — tolerant DESCRIPTION/TAGS extractor
  - [x] `Pipeline.swift` — orchestrates with `PromptStyle` (`bare`, `sideChannel`, `hybrid`)
  - [x] `ImageDownsizer.swift` — CGImageSource thumbnail-based downsize, EXIF baked
- [x] `photo-snail-cli` executable:
  - [x] Accepts image paths as args, supports multiple
  - [x] Human and `--json` output
  - [x] Flags: `--model`, `--bare`, `--hybrid`, `--no-downsize`, `--json`

### Phase C — Validation against the two test photos ✅
- [x] Run hybrid pipeline on `IMG_0536.jpeg` (cats)
- [x] Run hybrid pipeline on `CA6EF8EE-…_1_105_c.jpeg` (Sparco seats)
- [x] Compare against the bare-prompt gemma4:31b runs from the feasibility test
- [x] **Finding**: in-prompt hybrid was ~2× slower at generation for marginal quality gain → adopted **side-channel (v3)** instead. Vision still runs (for OCR rescue + structured metadata) but stays out of the LLM prompt. Repeatability test confirmed 3/3 spatial accuracy at bare-arm speed.
- [x] **Locked design rules** (see top of file)
- [x] Implemented 1024 px downsize via `ImageDownsizer` — ~3× speedup, no quality loss

### Phase D — Broader sample test (20 photos) ✅
- [x] Ran v3 pipeline on 20 real HEIC photos from the user's library (`sample/`)
- [x] Hand-rated description and tag quality for every photo
- [x] **Result**: 14/20 fully accurate, 6/20 minor cosmetic issues, 0/20 significant failures
  - Cats: 9/9 ✓ (100%)
  - Whiteboards: 2/2 ✓
  - Product label: 1/1 ✓
  - Tattoo: 1/1 ✓
  - Maker/electronics: 1/7 fully accurate, 6/7 minor issues (component-type confusion, niche brands not in LLM training)
- [x] **Steady-state timing**: ~64.5 s/photo on the M-series machine; ~7.5 days extrapolated for 10k photos
- [x] OCR rescue tuning: added bilingual EN+FR stop-list to `Pipeline.ocrStopwords` to drop junk like `type` (from `TYPE-C`) without losing short brand names
- [x] **Locale decision**: trialled French prompt with brand preservation; reverted same day. Pipeline emits English. Bilingual OCR stop-list retained because French OCR text can still appear from real-world signage.

### Phase E — Persistent queue & resumability ✅
- [x] SQLite schema: `assets(id, status, attempts, error, processed_at, description, tags_json)`
- [x] Status transitions: `pending → in_progress → done | failed`
- [x] Resume on startup: re-queue any `in_progress` rows that didn't reach `done`
- [x] Bounded retries with backoff for transient failures (Ollama down, etc.) — 3 attempts, 10s/30s/60s
- [x] Configurable concurrency (default 1; Ollama serializes anyway) — `--concurrency N` flag

### Phase F — PhotoKit integration ✅

**Architecture decisions (locked 2026-04-07, updated 2026-04-10 after F.1 spike):**
- **Bundle shape**: full Xcode `.app` project alongside `Package.swift`, importing `PhotoSnailCore` as a local SPM dependency. SPM-only is not sufficient because PhotoKit + Photos.app scripting needs entitlements + Info.plist privacy strings.
- **Pipeline entry point**: NEW parallel `Pipeline.process(asset: PHAsset)` that pulls the image via `PHImageManager` directly (no temp-file detour). The existing `process(imagePath:)` keeps working unchanged for the CLI.
- **Write-back path**: **Option B — description-only via NSAppleScript** (updated 2026-04-10). PhotoKit's `PHAssetChangeRequest` does NOT expose title/description/keywords for writes. The spike validated that Photos.app's AppleScript `description` property is the ONLY field that: (a) is writable via AS, (b) syncs to iOS via iCloud, (c) supports `whose description contains "X"` queries for sentinel filtering. Title and keywords do NOT sync to iOS, and `whose keywords contains {"X"}` is structurally broken in Photos.app's AS dictionary. See `memory/project_phase_f1_spike_results.md` for the full spike findings.
- **Description format**: everything in ONE field — `<LLM prose description>. Tags: tag1, tag2, ..., ai:gemma4-v1`. The sentinel marker `ai:gemma4-v1` is embedded in the description text, searchable on both Mac and iOS.
- **NSAppleScript MUST run on the main thread** via `await MainActor.run { ... }`. Apple Event replies are dispatched to the main thread's CFRunLoop; calling from a cooperative thread pool hangs for ~30 s/call due to a Carbon-era WaitNextEvent fallback. See `memory/project_phase_f1_spike_results.md`.
- **`id of media item` returns the full PHAsset.localIdentifier format** (`<UUID>/L0/001`, 43 chars). Lookups use the stripped UUID prefix (36 chars). Sentinel-filter id matching needs prefix comparison, not exact equality.

#### Phase F.1 — Spike harness ✅ (signed off 2026-04-10)
- [x] Built standalone `phase-f-spike` SPM executable with linker-embedded Info.plist
- [x] Verified on the user's actual 7,000-photo library — all 5 checks pass:
  - [x] Photos.app Info inspector shows the description with embedded tags + sentinel
  - [x] All tags + sentinel surface in Photos.app search bar on Mac (the make-or-break test)
  - [x] iCloud round-trip — description (with embedded tags) visible on iPhone, searchable there
  - [x] Re-running with identical input is idempotent (no description drift)
  - [x] `whose description contains "ai:gemma4-v1"` returns the target asset (via prefix match on the /L0/001-suffixed id)
- [x] Measured per-call wall-clock latency: ~100 ms steady-state (warm), ~1.3 s cold first call. 10k photos extrapolates to ~17–25 min for the AS layer alone — well within the 30–80 min budget.
- [x] **Critical findings documented in `memory/project_phase_f1_spike_results.md`**: MainActor requirement, description-only design, `whose keywords` broken, id format mismatch

#### Phase F.2 — Main implementation ✅ (2026-04-10)
- [x] SPM executable target `photo-snail-app` with linker-embedded Info.plist (same pattern as spike — Xcode project deferred to Phase G when SwiftUI is needed)
- [x] `Info.plist`: `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `NSAppleEventsUsageDescription`
- [x] Request `PHAuthorizationStatus(for: .readWrite)`; handle denied/limited cases
- [x] Refactored `Pipeline.process(imagePath:)` to extract private `processCore(imageData:identifier:pixelWidth:pixelHeight:)` helper; added new `process(imageData:identifier:)` public entry point for PhotoKit
- [x] Added in-memory entry points: `ImageDownsizer.downsizedJPEG(data:)`, `VisionAnalyzer.analyze(imageData:)`, `OllamaClient.generateCaption(model:prompt:imageData:sourcePixelWidth:sourcePixelHeight:)`
- [x] `PhotoSnailApp/PhotosScripter.swift` — productized from spike: `runBatch(uuid:descriptionPayload:)` with MainActor, `findAssetsByDescriptionMarker(_:)` for sentinel bootstrap
- [x] `PhotoSnailApp/PhotoLibraryEnumerator.swift` — fetches all image assets, enqueues to SQLite queue, bootstraps from sentinel marker on first run
- [x] `PhotoSnailApp/QueueRunner.swift` — full orchestration: auth → enumerate → queue → pipeline → write-back → markDone. Critical ordering preserved (markDone only after scripter succeeds).
- [x] `Pipeline.formatDescription(description:tags:sentinel:)` — produces `<description>. Tags: tag1, ..., ai:gemma4-v1`
- [x] `AssetQueue.markBootstrapped(_:)` — marks sentinel-found assets as done without PipelineResult
- [x] Verified end-to-end on real library (7,632 assets): auth, bootstrap (found 1 spike asset), pipeline processes PHAsset image data, descriptions with embedded tags + sentinel land in Photos.app, sentinel filter works, idempotent re-run skips done assets, queue resumes across restarts
- [x] Deleted `Sources/phase-f-spike/` and its `Package.swift` entries
- [x] Added `--limit N`, `--dry-run`, `--list` flags for controlled testing
- [ ] ~~Minimal SwiftUI surface~~ → deferred to Phase G (terminal progress output sufficient for batch runs)

### Phase G — SwiftUI GUI app (PhotoSnail.app) ✅ (2026-04-10)
- [x] Status bar: total / done / pending / failed counts + progress bar
- [x] Top half: last completed photo thumbnail + description + tags (flow layout with sentinel highlighting)
- [x] Bottom half: currently processing photo thumbnail + progress indicator + asset ID
- [x] Start / pause / resume controls (pause finishes current photo before suspending)
- [x] Throughput (photos per hour) + ETA
- [x] Failure inspector (collapsible sidebar, error detail, Retry / Retry All buttons)
- [x] Proper `.app` bundle via `bundle-gui.sh` (SPM build + packaging script)
- [x] New SPM target `photo-snail-gui` alongside preserved `photo-snail-app` CLI
- [x] `AssetQueue.listFailed()`, `requeueFailed()`, `FailedRow` for failure inspector
- [x] Platform bumped to `.macOS(.v14)` for `@Observable` macro
- [x] `ProcessingEngine` — `@Observable @MainActor` state machine with `Task.detached` worker + `CheckedContinuation` pause/resume

### Feature: configurable model + Ollama connection ✅ (2026-04-11)
- [x] `PhotoSnailCore/Settings.swift` — Codable, JSON at `~/Library/Application Support/photo-snail/settings.json` (mode 0600), atomic save, env-var override via `withEnvOverrides()`
- [x] `PhotoSnailCore/Sentinel.swift` — `family(of:)`, `family(ofSentinel:)`, `propose(forModel:currentSentinel:)`. Switching tags within a family does not propose a new sentinel; switching families does.
- [x] `PhotoSnailCore/OllamaClient.swift` — `OllamaConnection` (baseURL/apiKey/headers), `OllamaModel`, `listModels()` against `/api/tags`, `applyAuth(to:)` for both Bearer + custom headers
- [x] CLI flags: `--list-models`, `--ollama-test`, `--ollama-url`, `--ollama-key`, `--ollama-header K=V`, `--keep-sentinel`. Family-change gate refuses model switches without explicit `--sentinel` or `--keep-sentinel` (exit 2).
- [x] `PHOTO_SNAIL_OLLAMA_API_KEY` env-var override — applied at runtime, never persisted to disk.
- [x] GUI: `ProcessingEngine` loads settings + fetches models in background. New `SettingsSheet.swift`: model picker, sentinel choice (keep / propose / custom), Ollama connection (base URL, API key with show toggle, advanced custom headers, Test Connection button). Toolbar gear icon opens it.
- [x] Smoke-tested: `--list-models` against live Ollama, family-gate exit 2, family-gate accepts `--keep-sentinel` and `--sentinel`, bad URL fails clearly, key redacted as `sk-***`, env var picked up, custom headers parsed.
- Documented in CLAUDE.md (settings shape, security tradeoff, family rule, all flags).
- Known minor bug: diagnostic flags (`--list-models`, `--ollama-test`) return before settings save, so combining them with `--ollama-url` etc. doesn't persist. Re-run without the diagnostic flag.

### Phase UI — Library revamp (in progress, started 2026-04-11)

_Replace the "batch monitor" GUI with a full library browser: grid of every photo, status badges, inspector with full processing provenance, tag-filter on right-click, bulk operations, runner dock pinned to sidebar. Design: Option A (Photos-native NavigationSplitView) with Option-C thoroughness in the inspector. macOS 14+. See the plan in the conversation memory / chat._

#### Phase 1 — Data layer (no visible UI change) ✅ (2026-04-11)
- [x] `AssetQueue`: schema migration from `user_version` 0 → 1. Adds nullable columns: `model`, `sentinel`, `vision_json`, `vision_ms`, `ollama_ms`, `total_ms`, `updated_at`.
- [x] `AssetQueue`: one-time backup of `queue.sqlite` (+ `-wal`/`-shm`) to `queue.sqlite.pre-v1.backup` before the first migration. Skipped if already at v1 or on a brand-new DB.
- [x] `AssetQueue.markDone` gains a required `sentinel:` parameter and persists the new fields from `PipelineResult`.
- [x] New queue methods: `fetchAllRows()`, `fetchRow(id:)`, `updateDescription(id:description:tags:)`, `requeue(_:)`, `clearResult(_:)`.
- [x] New public `AssetQueue.Row` struct exposing the full row shape for the library view.
- [x] Call-site updates: `Sources/PhotoSnailApp/QueueRunner.swift`, `Sources/PhotoSnailGUI/ProcessingEngine.swift`, `Sources/photo-snail-cli/main.swift` all pass `sentinel:` through.
- [x] New `--verify-queue` flag on `photo-snail-app` as a health check + migration trigger.
- [x] Build: `swift build -c release` green in 2.6 s.
- [x] Verified on the real 7,632-row queue: pre-migration `user_version=0`, post-migration `user_version=1`, `queue.sqlite.pre-v1.backup` created with the pre-v0 schema and same row counts, `pragma table_info(assets)` shows 14 columns, row counts unchanged (534 done / 7,098 pending / 0 failed), idempotent on re-run (backup mtime unchanged).
- [ ] **Still to verify**: real `markDone` actually populates the new columns. Happens automatically on the next real processing run (not dry-run).

#### Phase 2 — LibraryStore + grid skeleton ✅ (2026-04-11)
- [x] `@Observable @MainActor LibraryStore`: holds `PHFetchResult<PHAsset>` + `[String: AssetQueue.Row]` cache. Inverted tag index deferred to Phase 4 (when tag filtering actually lands).
- [x] `AsyncStream<QueueChange>` on `AssetQueue`: new `QueueChange` enum, subscriber map, `changes()` method, broadcast calls wired into every mutating method (enqueue, claimNext, recordRetry, markDone, markBootstrapped, markFailed, requeueFailed, updateDescription, requeue, clearResult).
- [x] New `LibraryWindow` with three-column `NavigationSplitView` (sidebar / content / detail).
- [x] `LazyVGrid` with adaptive columns, per-cell `PHImageManager.requestImage` (fastFormat), status badges (green/amber/red dots). `PHCachingImageManager` deferred to Phase 7 if scroll perf is a problem on large libraries.
- [x] Feature flag flipped: `PHOTO_SNAIL_NEW_UI=1` opts IN to the new UI, default stays on the old `ContentView`. Safer during development — regressions don't surprise a normal launch.
- [x] Verified: build clean, bundle packaged, launched with env var, 30+ s alive at 0.1% CPU / 140 MB, user-visible sidebar counts match the queue (7,632 / 534 tagged / 7,098 pending / 0 failed), selection → inspector placeholder works.

#### Phase 3 — Inspector (thoroughness) ✅ (2026-04-11)
- [x] Hero preview via `PHImageManager.requestImage(.highQualityFormat)` with degraded-callback guard.
- [x] Identity section: filename (KVC `filename` on `PHAsset`), created/modified dates, dimensions, media type, favorite star, raw lat/lon, album membership (via `PHAssetCollection.fetchAssetCollectionsContaining`), full asset id. Reverse-geocoding deferred to Phase 7.
- [x] Description editor: `TextEditor` with draft state, dirty-dot indicator, Save/Revert buttons, inline error reporting. Save path: `PhotosScripter.runBatch` (main thread) + `queue.updateDescription` — the sentinel is preserved from the stored row (per the user's "edits are refinements, not new generations" decision), falling back to `Settings.default.sentinel` only for pre-v1 rows.
- [x] Tag chips in a custom `ChipFlowLayout` (macOS 14 `Layout` protocol). Click = toggle tag filter, right-click = context menu (View photos / Copy tag / Remove from this photo in edit mode). Active filter shown with accent background + border.
- [x] Processing provenance: status, model, sentinel, ran-at, timings (including a two-tone `TimingBar` showing Vision vs Ollama split), attempts, last error, edited-at.
- [x] Vision findings: top-5 classifications with confidence bars, animal/face counts, OCR text, Vision time. Stop-list greying deferred to Phase 7.
- [x] Developer section (collapsed `DisclosureGroup`): every raw queue column + the exact `Pipeline.formatDescription` payload that was / would be written to Photos.app.
- [x] LibraryStore additions: loads `Settings` at startup for the `currentSentinel` fallback, exposes `activeTagFilter` with `setTagFilter(_:)`, `saveDescription(id:description:tags:)` entry point. `rebuildDisplayOrder` composes base filter AND tag filter.
- [x] Grid gains a small active-filter strip above the thumbnails when `activeTagFilter != nil`, with a one-click ✕ to clear.
- [x] Verified: build clean, GUI launches with `PHOTO_SNAIL_NEW_UI=1`, all seven inspector sections render, selection switch resets all per-photo state, tag-filter round-trips work, pre-v1 rows gracefully show "—" for unrecorded fields.

#### Phase 4 — Filters, search, tag-filter magic
- [ ] Sidebar filter list (All / Tagged / Untouched / Pending / Failed) with live counts.
- [ ] Active filter chip strip (AND semantics).
- [ ] Popular tags section (top 20 by frequency in current base filter).
- [ ] Text search (debounced, matches on description + tags via the in-memory cache).
- [ ] Right-click on a tag chip → "View photos with this tag" sets the filter.

#### Phase 5 — Bulk operations
- [ ] Multi-select state in the grid (cmd/shift-click, arrow range, ⌘A/D).
- [ ] Bulk action bar (visible when selection > 0): Re-process · Clear description · Copy tags · Export JSON.
- [ ] Confirmation dialogs for destructive ops (Clear description).
- [ ] Progress sheet with cancel button for AppleScript-heavy ops.

#### Phase 6 — Runner dock + engine migration
- [ ] Compact runner card pinned to the bottom of the sidebar (last-completed + current + start/pause/resume + stats).
- [ ] Current/last photo cards live there permanently (per user request #5).
- [ ] Failures become the "Failed" filter; delete `FailureListView`.
- [ ] Delete old `ContentView`, `StatusBar`, `ControlsView`, `CompletedPhotoView`, `CurrentPhotoView`. New `LibraryWindow` is the default.

#### Phase 7 — Polish
- [ ] Keyboard shortcuts (⌘F, ⌘1/2/3, ⌘A/D, arrow nav, Space QuickLook, E edit, ⌘⏎ save, R reprocess, ⌫ clear).
- [ ] Hover states, 150 ms fades, tabular figures.
- [ ] `SceneStorage` for window size / split widths / inspector collapsed.
- [ ] Badge legend in a toolbar "?" popover.
- [ ] Light + dark mode review.

#### Phase 8 — Settings sheet refresh
- [ ] Same capabilities as today (model / sentinel / Ollama).
- [ ] Add: default thumbnail size, default sort order, "Follow current processing in grid" toggle.
- [ ] Visual pass to match the rest of the revamp.

### Phase H — (deferred) Production polish
_Phase H was planned as an optional polish layer. A mid-batch review on 2026-04-11 (535/7,632 photos done, 0 failed) showed no quality issues that would justify the originally-planned work — descriptions averaged ~196 chars, tag counts 7–14, zero duplicates, zero failures. The four original items have been moved to "Potential future improvements" below. The active roadmap (Phases A–G) is complete and the CLI/GUI are in production use._

## Potential future improvements

_Not on the active roadmap. Captured so the rationale isn't lost. Each is independent and can be picked up later if a concrete need surfaces._

- **Quality scoring heuristic** — detect short/generic outputs and re-run with a stronger prompt. **Deferred**: the 535-photo production sample showed no cluster of weak outputs to rescue (avg description length ~196 chars, zero duplicates across the sample, tag counts healthy 7–14). Revisit only if the remaining photos surface a pattern worth automating around.
- **Claude Opus escalation pass** — optional cloud-based re-caption on a user-selected album (favorites, portfolio shots) for the ~5–10% of photos where top-shelf quality is worth the ~$0.10/photo. Self-contained work: album picker UI, cloud call path, a separate sentinel (e.g. `ai:opus-4-6-v1`) so it's idempotent and distinguishable from the local-LLM pass. Explicitly breaks the "fully local default" priority and must remain opt-in.
- **Prompt v2 / sentinel bump** — re-run the full library with a new prompt by bumping sentinel to `ai:gemma4-v2`. Infrastructure is trivial (one constant + a migration path); only meaningful once there's a concrete v2 prompt in hand that outperforms the current one on a blind A/B.
- **IPTC/XMP export to original files** — write description and tags into IPTC/XMP metadata on a *copy* of the original file (never mutating originals in place). Portability hedge for the day the user leaves Photos.app or wants embedded metadata readable by other tools. Touches file-system layout and needs a destination-directory convention.

## Open questions

- ~~**Image size for the LLM**: 1024 px assumed but unverified.~~ ✅ Locked at 1024 px long edge, JPEG q=0.8. Validated through Phase D — no quality degradation observed.
- ~~**Prompt language**: descriptions in English by default.~~ ✅ English. French was trialled and reverted (2026-04-07).
- ~~**Sentinel keyword visibility**: `ai:gemma4-v1` will appear in Photos search. Acceptable, or should we hide it via a less-searchable mechanism?~~ ✅ Resolved 2026-04-07: kept as a normal visible tag in the merged tag set. User explicitly wants it visible.
- **Original-file metadata**: not in scope for v1 (Photos.app metadata only via Option B scripting). Defer to Phase H if the user wants embedded IPTC/XMP exportability — that's the Option C hybrid path.

## Measured numbers (locked after Phase D, 2026-04-07)

| Metric | Value |
|---|---|
| Steady-state per photo (warm gemma4:31b, downsized image, side-channel v3) | **~64.5 s** |
| 1,000 photos | ~18 hours |
| 10,000 photos | **~7.5 days** continuous (or ~15 overnight runs of 12 h) |
| Image sent to model | 768×1024 / ~95–250 KB JPEG (downsized from 12–24 MP source) |
| Output tokens per photo | ~60–80 |
| Vision pre-pass cost | ~400 ms – 1.2 s (negligible) |
| Quality on 20-photo sample | 14/20 fully accurate, 6/20 minor cosmetic, 0/20 failures |

Other models considered and disqualified:
- `gemma4:latest` (~5 s/photo): made spatial errors → disqualified for default
- Claude Opus 4.6 vision (~16 s/photo, highest quality): cloud + paid (~$0.10/photo, ~$1000 for 10k photos), privacy → not the default; available as optional Phase H escalation

## Memory references

The full decision history and findings are in `~/.claude/projects/-Users-laurentchouinard-claude-photo-snail/memory/`:
- `feedback_ollama_timing.md` — verify Ollama isn't double-loaded before benchmarking
- `project_vision_vs_llm_complementarity.md` — Vision vs LLM complementary, not redundant
- `project_hybrid_prompt_bias_finding.md` — first hybrid spatial regression (since proven to be variance, not bias)
- `project_v3_side_channel_validated.md` — v3 architecture decision and supporting numbers
- `project_phase_d_quality_assessment.md` — 20-photo Phase D results and tuning recommendations
- `project_locale_decision.md` — English/French locale decision history

## Review

**Phase A–D complete (2026-04-06 → 2026-04-07).**
- Architecture: locked to v3 (Vision side-channel + bare LLM prompt), validated on 26 real photos across cats, electronics, scenes, whiteboards, product labels, art
- Codebase: ~600 lines of Swift across `PhotoSnailCore` + CLI; builds clean in release mode in <5 s
- Performance: ~64.5 s/photo, predictable, no outliers across the 20-photo Phase D batch
- Quality: 70% fully accurate, 30% minor cosmetic, 0% failures on the broad sample
- The CLI is usable today; the architecture is ready for the persistent queue + PhotoKit layers

**Phase E complete (2026-04-07).**
- New files: `Sources/PhotoSnailCore/SQLite.swift` (~155 lines, thin C wrapper around the system SQLite3 module — zero new SPM deps), `Sources/PhotoSnailCore/AssetQueue.swift` (~165 lines, actor-based queue)
- Edits: `Package.swift` (links `libsqlite3` from `PhotoSnailCore`), `Models.swift` (`PhotoSnailError.isRetriable` + `shortMessage`), `main.swift` (`--queue`, `--db`, `--concurrency` flags + `runQueue` worker loop using `withTaskGroup`)
- Schema matches the spec exactly: `assets(id, status, attempts, error, processed_at, description, tags_json)`. WAL mode on for crash safety.
- Default DB at `~/Library/Application Support/photo-snail/queue.sqlite`, overridable via `--db`.
- Atomic claim via `BEGIN IMMEDIATE` + select-then-update; attempts bumped at claim time so a crash mid-task doesn't lose attempt tracking.
- Resume sweep on init: `UPDATE assets SET status='pending' WHERE status='in_progress'`. Attempt counts preserved.
- Retry policy: 3 attempts max, exponential backoff 10s/30s/60s, applied only to `.ollamaRequestFailed`. Permanent errors (`.imageLoadFailed`, `.ollamaResponseParseFailed`) skip retries entirely.
- Per-worker `Pipeline` instance keeps the existing classes from needing `Sendable` conformance — config (model, prompt style, image options) is captured into each `addTask` closure and the non-Sendable `Pipeline` is constructed inside.
- Backward compat: invocations without `--queue` are byte-identical to Phase D — no DB created, no persistence touched.
- Verified end-to-end on real HEIC samples: clean run (2 photos → both `done`, attempts=1), idempotent re-run (44 ms no-op), permanent failure path (missing file → `failed` immediately, attempts=1), transient failure path (bogus model → 3 attempts with 10s/30s sleeps then `failed`), and resume sweep (manually-seeded `in_progress` row → swept to `pending` and re-claimed without losing prior attempt count).
- ~325 lines of new Swift across the two new files; CLI delta is contained to the runner function and a few flag-parsing lines. Release build is still under 5 s.

**Phase F complete (2026-04-10).**
- Two layers: PhotoSnailCore got in-memory image variants (`ImageDownsizer.downsizedJPEG(data:)`, `VisionAnalyzer.analyze(imageData:)`, `OllamaClient.generateCaption(imageData:)`, `Pipeline.processCore` refactor + `process(imageData:identifier:)` + `formatDescription`). New `photo-snail-app` SPM executable target (`Sources/PhotoSnailApp/`: `PhotoLibrary.swift`, `PhotosScripter.swift`, `PhotoLibraryEnumerator.swift`, `QueueRunner.swift`, `App.swift`, `Info.plist`).
- Full pipeline: PhotoKit auth → enumerate all image assets → SQLite queue → pipeline (Vision + gemma4:31b) → AppleScript write-back (description-only with embedded tags + sentinel) → markDone.
- Sentinel bootstrap: on first run, queries Photos.app for existing `ai:gemma4-v1` markers and marks those assets as done in the queue. Subsequent runs use the SQLite queue as source of truth.
- Verified on the user's real 7,632-photo library: auth, bootstrap, pipeline, write-back, sentinel searchability, idempotent re-run, queue resume.
- Spike (`Sources/phase-f-spike/`) deleted. Build is clean in ~2s.
- CLI (`photo-snail-cli`) unchanged and backward-compatible.

**Phase G complete (2026-04-10).**
- New `photo-snail-gui` SPM target (`Sources/PhotoSnailGUI/`, 11 files) + `bundle-gui.sh` packaging script.
- SwiftUI app with `@Observable @MainActor ProcessingEngine`: status dashboard, two-panel photo display (completed top / processing bottom), start/pause/resume, throughput/ETA, failure inspector with retry.
- `AssetQueue` gained `listFailed()`, `requeueFailed()`, `FailedRow` struct.
- Platform bumped to `.macOS(.v14)` for `@Observable`. CLI targets unaffected.
- `PhotoLibrary.swift`, `PhotosScripter.swift`, `PhotoLibraryEnumerator.swift` copied from PhotoSnailApp (minor logging adaptation).
- Build: `./bundle-gui.sh` → `open .build/release/PhotoSnail.app`. CLI (`photo-snail-app`) preserved as-is, shares the same SQLite queue.

**Active roadmap complete as of Phase G.** Phase H deferred 2026-04-11 — see "Potential future improvements". Mid-batch quality check at 535/7,632 done, 0 failed: avg description ~196 chars, tag counts 7–14, zero duplicates, no weak-output cluster. The Phase F.1 bootstrap asset row (`64EAA6CF-…`) was reset to `pending` on 2026-04-11 so it's processed by the pipeline like any other asset when the batch resumes (the Photos.app write-back will replace the spike's test description).
