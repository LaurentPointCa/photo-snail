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

### Phase H — Production polish (only if needed)  ← NEXT
- [ ] Quality scoring heuristic: short/generic outputs → re-run with stronger prompt
- [ ] Optional Claude Opus escalation pass on a user-selected album (favorites, etc.)
- [ ] Optional re-run with prompt v2 by bumping sentinel to `ai:gemma4-v2`
- [ ] Export tags to original-file IPTC for portability outside Photos.app

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

**Active phase: H** (Production polish) — unstarted. CLI batch run in progress (~7,630 photos).
