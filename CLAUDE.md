# CLAUDE.md — photo-snail

Reference for future Claude agents working in this codebase. Read this BEFORE making changes.

## Purpose

Local-first Mac tool that auto-generates descriptions and tags for the user's macOS Photos library, writing the results back to each `PHAsset`'s metadata so they're searchable in Photos.app.

The user's priorities, in order:

1. **Quality** — accurate, specific descriptions
2. **Privacy** — fully local, no cloud APIs in the default path
3. **Resilience** — multi-day batches must survive sleep/wake/restart
4. **Idempotency** — re-running on a processed library is a no-op
5. **Speed** — last priority; ~65 s/photo is acceptable

## Status

Phases A–K complete. The CLI (`photo-snail-app`) processes the full Photos library end-to-end. The GUI (`PhotoSnail.app`) provides a SwiftUI dashboard with live photo preview, status, pause/resume, failure inspector, custom prompt editor, and runtime localization (8 languages). Both share the same SQLite queue. Phase H was deferred on 2026-04-11 after a mid-batch quality review showed no weak-output cluster to rescue — see `TODO.md` → "Potential future improvements" for the parked items.

See `TODO.md` for the phased plan and current progress.

## Architecture

Hybrid pipeline running fully on-device:

```
PHAsset (or local file path)
  ↓
ImageDownsizer       — CGImageSource thumbnail to 1024 px long edge, JPEG q=0.8
  ↓
[parallel signals]
  ├─ VisionAnalyzer  — VNClassifyImageRequest, VNRecognizeAnimalsRequest,
  │                    VNDetectFaceRectanglesRequest, VNRecognizeTextRequest
  │                    (~400 ms – 1.2 s per photo)
  └─ OllamaClient    — gemma4:31b via http://localhost:11434/api/generate
                       with bare prompt + downsized JPEG (~60 s per photo)
  ↓
CaptionParser        — extracts DESCRIPTION/TAGS from raw model response
  ↓
mergeTags            — LLM tags + LLM-confirmed OCR rescue (cross-check filter)
  ↓
PipelineResult       — caption, tags, vision findings, timing
```

The Vision pre-pass runs as a **side channel**: its findings are NOT injected into the LLM prompt. They flow downstream only for OCR brand rescue and as structured metadata. This was the key architectural decision — see "Why side-channel" below and `project_v3_side_channel_validated.md`.

## Why these technical choices

### Local LLM via Ollama (not cloud, not Vision-only)

The user's photo library is intimate (family, kids, home, documents). Cloud APIs were considered and rejected as the default:

- **Claude Opus 4.6 vision**: highest quality but ~$0.10/photo (~$1000 for 10k photos), and uploads everything off-device. Reserved as an optional Phase H escalation pass for select albums.
- **Apple Vision alone**: 400 ms/photo, deterministic, but the classifier covers only ~1303 ImageNet-style labels and cannot describe niche objects (returned "luggage / sneaker" for racing seats). Cannot generate prose descriptions at all.
- **Local LLM (gemma4:31b)**: genuinely good descriptions, no per-photo cost, fully private. Slow (~65 s/photo) but the user explicitly accepted that trade.

### gemma4:31b, not gemma4:latest

`gemma4:latest` (~9.6 GB, ~5 s/photo) is 14× faster but failed a spatial-reasoning test on the cats image — described the white cat as "playing with electronics" instead of correctly noting the black cat sat on the speaker. For a 10k-photo run that gets baked into metadata, locking in that error rate is unacceptable. The 31B model was 3/3 on the same spatial test.

### Side-channel Vision, not in-prompt Vision

The first hybrid design injected Vision findings into the LLM prompt as context. A repeatability test (3× bare vs 3× hybrid on the same image) showed:

- **Quality parity**: both arms got 3/3 spatial accuracy
- **2.4× generation slowdown** for in-prompt hybrid because the longer prompt context (592 vs 331 tokens) increases per-token attention work in the KV cache

So Vision was kept, but pulled out of the prompt. The LLM gets the bare prompt; Vision findings flow into a separate channel for OCR rescue and structured metadata. Same quality, full speed.

### 1024 px downsize before sending to Ollama

24 MP source images took ~210 s/photo through the pipeline; downsized 768×1024 JPEGs take ~65 s. The downsize is done with `CGImageSourceCreateThumbnailAtIndex` which never decodes the full source — it builds the thumbnail directly from the embedded preview when possible. EXIF orientation is baked in via `kCGImageSourceCreateThumbnailWithTransform`.

### Bare prompt + LLM-confirmed OCR cross-check rescue

Tag merging strategy in `Pipeline.mergeTags`:

1. LLM tags first (authoritative)
2. OCR tokens are added IF (a) length 4–20, (b) NOT in the bilingual EN+FR `ocrStopwords` set, (c) the LLM's free-text response also mentions them anywhere

The cross-check rule was the key insight: rather than trying to filter OCR garbage with regex or dictionaries, use the LLM as the sanity check. If the LLM mentioned a word in its prose, it's a real word from the image. This rescues `sparco`/`sprint`/`saeco`/`physics` cleanly while dropping `uto`/`eparco`/`rance`-style OCR noise.

The stop-list catches the residual edge case where a generic English/French word leaks through (`type` from `TYPE-C`, `with` from product copy, etc.).

### English prompt and output

The user lives in QC (French context). A French prompt with brand preservation was trialled and worked (~10% slowdown, fluent French descriptions, brands preserved). User reverted to English the same session. The bilingual stop-list is kept regardless because OCR text can still be French even when the LLM speaks English.

If asked to revisit French, see `project_locale_decision.md` — the prompt template is documented there.

### Configurable Ollama connection + sentinel (added 2026-04-11)

Both apps now read/write `~/Library/Application Support/photo-snail/settings.json` (file mode `0600`):

```json
{
  "version": 1,
  "model": "gemma4:31b",
  "sentinel": "ai:gemma4-v1",
  "ollama": { "baseURL": "http://localhost:11434", "apiKey": null, "headers": {} }
}
```

Missing file → `Settings.default` (today's hardcoded values). Saved atomically via temp file + rename, with `chmod 0600` BEFORE the rename so the API key is never world-readable on disk.

**API key storage tradeoff**: plain text on disk. Mitigations: (1) `0600` permissions, (2) redacted as `sk-***` in all logs/CLI output via `OllamaConnection.redactedKey`, (3) `PHOTO_SNAIL_OLLAMA_API_KEY` env var overrides at runtime and is **never** persisted (`Settings.withEnvOverrides()` applies it post-load, and `ProcessingEngine.applyConfigChange` strips the env value before saving). Keychain storage was deferred — adding `Security.framework` + TCC prompts wasn't worth the complexity for a single-user local tool. Documented in the GUI Settings sheet.

**Sentinel family rule** (`Sources/PhotoSnailCore/Sentinel.swift`): the sentinel format is `ai:<family>-v<N>` where `<family>` is `model.split(":").first` lowercased and sanitized (non-alphanumerics → `-`, runs collapsed, leading/trailing `-` trimmed). Switching between two tags within the same family (`gemma4:31b` ↔ `gemma4:latest`) does NOT propose a new sentinel. Switching to a different family proposes `ai:<newfamily>-v1` and the user must explicitly accept it (`--sentinel`) or reject it (`--keep-sentinel`).

**CLI gate** (`photo-snail-app`): a family change without `--sentinel` or `--keep-sentinel` exits with code 2 and a multi-line error showing the three resolution options. The gate runs in `mergeSettings` BEFORE the diagnostic flags (`--list-models`, `--ollama-test`), so combining them with a model change still triggers the gate.

**Diagnostic flags** (return early, don't save settings, don't touch the queue):
- `--list-models` — hits `/api/tags`, prints a table with `*` next to the current model
- `--ollama-test` — same as `--list-models` but only reports OK/FAIL + count

**Connection flags**: `--ollama-url`, `--ollama-key`, `--ollama-header K=V` (repeatable). Override the on-disk settings for this run AND get persisted on a non-diagnostic invocation. Headers are applied AFTER the `apiKey` Bearer header in `OllamaClient.applyAuth`, so a `--ollama-header Authorization=Basic ...` will override `--ollama-key`. Use this for proxies that don't speak Bearer.

**Known minor bug**: diagnostic commands (`--list-models`, `--ollama-test`) return before the settings-save step, so combining them with config flags (`--model`, `--ollama-url`, etc.) won't persist the config. Workaround: re-run without the diagnostic flag. Not worth fixing unless it bites someone — diagnostics are inherently read-only by intent.

### Custom prompt + sentinel version bumps (added 2026-04-12)

`Settings.customPrompt` (optional, nil = use default) stores a user-edited prompt. `PromptBuilder.bare(override:)` uses it when non-nil. When the prompt changes, the sentinel version is bumped (e.g. `ai:gemma4-v1` → `ai:gemma4-v2`) so new results are distinguishable from old ones. The SettingsSheet offers to requeue photos processed under old sentinels.

`Sentinel.bumpVersion(currentSentinel:)` parses the current version and returns `ai:<family>-v<N+1>`. `Sentinel.version(ofSentinel:)` extracts the integer version.

### Runtime localization (added 2026-04-12)

The GUI supports 8 languages: EN, FR, ES, DE, PT, JA, ZH-Hans, KO. `Localizer.swift` is an `@Observable @MainActor` singleton. Views call `loc.t("key")` and re-render automatically when the language changes. Translations are in `Strings.swift` (~181 keys per language). Persistence: `UserDefaults` key `"photo-snail.language"`.

The Language menu (menubar → Language) triggers `LanguageChangeSheet`, which:
1. Confirms the switch in the current language
2. Offers to change the AI prompt language (bumps sentinel)
3. Offers to translate existing descriptions via Ollama (enqueues translation jobs)

### Translation pipeline (added 2026-04-12)

Queue schema v2 adds `task_type` (`'caption'` default, `'translate'`), `original_description`, `original_tags_json`. Translation jobs are text-only Ollama calls (~2-5s each, no image). The worker loop in `ProcessingEngine` branches on `claim.taskType`:
- `"caption"`: existing image pipeline (unchanged)
- `"translate"`: reads `original_description`/`original_tags_json`, sends translation prompt, parses result with `CaptionParser`, writes back to Photos.app

`AssetQueue.enqueueTranslation(_:)` snapshots current description/tags into `original_*` columns before setting rows back to pending. `OllamaClient.generateText(model:prompt:)` handles text-only calls.

### Dry-run is queue-pure (added 2026-04-11)

`--dry-run` (CLI) and `ProcessingEngine.dryRun` (GUI) both run the full pipeline (Vision + Ollama + parser + tag merge) but **never mutate the queue DB**. No `claimNext`, no `markDone`, no `markFailed`, no `recordRetry` — the row that was at the head of `pending` before the dry-run is still at the head afterwards.

The mechanism: at startup, the runner takes a read-only snapshot of all pending IDs via `AssetQueue.peekAllPendingIds()` and wraps it in a `DryRunCursor` actor. Workers pull IDs from the cursor's atomic `next()` call instead of `claimNext()`. The cursor is the only "list in memory" — once exhausted (or `--limit N` is hit), the dry-run exits and the cursor is discarded.

Errors in dry-run are logged with `[skipped <id>]` and the worker continues to the next ID. There's no retry, no markFailed — those would mutate the queue.

**Why this matters**: before this fix, `--dry-run` would run the pipeline, skip the AppleScript write-back (correctly), but still call `markDone` on the queue. The result was rows flagged as done with descriptions in the queue but no sentinel in Photos.app. The next real run would skip those rows and the user would silently end up with un-tagged photos. The fix is queue-pure: a dry-run on a 7,000-photo queue leaves all 7,000 rows untouched.

If you ever add new mutation calls in the worker loop (`QueueRunner.swift` or `ProcessingEngine.swift`), gate them on `if !dryRun { ... }`. The pattern is established in both files; follow it.

## Code layout

```
photo-snail/
├── Package.swift                      SPM manifest, macOS 13+
├── TODO.md                            Phased plan + current progress
├── CLAUDE.md                          (this file)
├── sample/                            20 user-provided HEIC photos for Phase D
├── Sources/
│   ├── PhotoSnailCore/                  Reusable library (no PhotoKit dependency)
│   │   ├── Models.swift               Codable types: VisionFindings, CaptionResult,
│   │   │                              PipelineResult, PromptStyle, PhotoSnailError
│   │   ├── ImageDownsizer.swift       CGImageSource thumbnail JPEG encoder (path + data)
│   │   ├── VisionAnalyzer.swift       Four Vision requests + EXIF orientation (path + data)
│   │   ├── OllamaClient.swift         async HTTP client, /api/generate + /api/tags listModels(),
│   │   │                              OllamaConnection (baseURL/apiKey/headers), OllamaModel
│   │   ├── PromptBuilder.swift        bare() and build(findings:) prompt builders
│   │   ├── CaptionParser.swift        Tolerant DESCRIPTION/TAGS extractor
│   │   ├── Pipeline.swift             Orchestration + tag merging + formatDescription
│   │   ├── Settings.swift             Persistent user settings (JSON, 0600), env-var overrides
│   │   ├── Sentinel.swift             family(of:) + propose(forModel:currentSentinel:) helpers
│   │   ├── AssetQueue.swift           Actor-based SQLite queue (Phase E) + markBootstrapped
│   │   └── SQLite.swift               Thin C wrapper around system sqlite3
│   ├── photo-snail-cli/main.swift       CLI driver (file-path-based, no PhotoKit)
│   ├── PhotoSnailApp/                   CLI Photos library processor (Phase F.2)
│   │   ├── Info.plist                 Linker-embedded plist for TCC (Photos + AppleEvents)
│   │   ├── PhotoLibrary.swift         PhotoKit auth + fetch + requestImageData + uuidPrefix
│   │   ├── PhotosScripter.swift       NSAppleScript write-back (description-only, MainActor)
│   │   ├── PhotoLibraryEnumerator.swift  Discovers unprocessed assets + sentinel bootstrap
│   │   ├── QueueRunner.swift          Full orchestration: enumerate → queue → pipeline → write-back
│   │   └── App.swift                  Entry point + arg parsing
│   └── PhotoSnailGUI/                   SwiftUI GUI app (Phase G)
│       ├── Info.plist                 GUI plist (no LSUIElement, shows in Dock)
│       ├── PhotoSnailApp.swift          @main SwiftUI App entry point
│       ├── ProcessingEngine.swift     @Observable @MainActor state machine
│       ├── ContentView.swift          Main window: status bar + split view + controls
│       ├── StatusBar.swift            Stat counters + throughput + ETA + progress
│       ├── PhotoPreview.swift         CompletedPhotoView (top) + CurrentPhotoView (bottom)
│       ├── ControlsView.swift         Start / Pause / Resume
│       ├── FailureListView.swift      Failed assets + error detail + retry
│       ├── SettingsSheet.swift        Modal: model picker, prompt editor, sentinel choice, Ollama connection
│       ├── Localizer.swift           @Observable runtime language switching (8 languages)
│       ├── Strings.swift             Localization string catalog (~181 keys × 8 languages)
│       ├── LanguageChangeSheet.swift  Multi-step language change dialog flow
│       ├── PhotoLibrary.swift         (copied from PhotoSnailApp)
│       ├── PhotosScripter.swift       (copied from PhotoSnailApp)
│       └── PhotoLibraryEnumerator.swift (adapted: logging via closure)
├── bundle-gui.sh                      Packages .build/release into PhotoSnail.app
└── .build/release/
    ├── photo-snail-cli                  CLI binary (file paths)
    ├── photo-snail-app                  CLI Photos library processor
    └── PhotoSnail.app/                  GUI app bundle
```

`PhotoSnailCore` is intentionally library-shaped — both `photo-snail-cli` (file paths) and `photo-snail-app` (PhotoKit) import it.

## Build and run

```bash
# Build
swift build -c release

# Single image
.build/release/photo-snail-cli /path/to/photo.heic

# Multiple images
.build/release/photo-snail-cli sample/IMG_0611.HEIC sample/IMG_0624.HEIC

# JSON output
.build/release/photo-snail-cli --json /path/to/photo.heic

# Compare modes (default is sideChannel)
.build/release/photo-snail-cli --bare /path/to/photo.heic    # control: no Vision pre-pass
.build/release/photo-snail-cli --hybrid /path/to/photo.heic  # in-prompt Vision (slower)

# Disable downsize (sends original full-resolution image)
.build/release/photo-snail-cli --no-downsize /path/to/photo.heic

# Different Ollama model
.build/release/photo-snail-cli --model gemma4:latest /path/to/photo.heic

# --- photo-snail-app (Photos library processor) ---

# List recent assets (discovery)
.build/release/photo-snail-app --list 10

# List models from Ollama (with current marked *)
.build/release/photo-snail-app --list-models

# Probe Ollama with the current connection config
.build/release/photo-snail-app --ollama-test

# Process entire library (enumerate → queue → pipeline → write-back)
.build/release/photo-snail-app

# Dry-run: pipeline only, no Photos.app write-back, no queue mutation.
# Uses an in-memory snapshot of pending IDs (DryRunCursor) so the queue is
# bit-for-bit unchanged afterwards. Safe to run on a real queue at any time.
.build/release/photo-snail-app --dry-run

# Limit to N photos (for testing)
.build/release/photo-snail-app --limit 5

# Switch model (same family — silent)
.build/release/photo-snail-app --model gemma4:latest

# Switch model family (REQUIRES --sentinel or --keep-sentinel)
.build/release/photo-snail-app --model llava:13b --sentinel ai:llava-v1
.build/release/photo-snail-app --model llava:13b --keep-sentinel

# Remote / proxied Ollama
.build/release/photo-snail-app --ollama-url https://ollama.my.lan --ollama-key sk-...
.build/release/photo-snail-app --ollama-header X-API-Key=...

# Avoid persisting the API key to disk
PHOTO_SNAIL_OLLAMA_API_KEY=sk-... .build/release/photo-snail-app

# Combined flags
.build/release/photo-snail-app --model gemma4:31b --limit 10 --dry-run

# --- PhotoSnail.app (SwiftUI GUI) ---

# Build and package
./bundle-gui.sh

# Launch
open .build/release/PhotoSnail.app

# Install to Applications
cp -R .build/release/PhotoSnail.app /Applications/
```

Ollama must be running locally on the default port (11434). Verify with `ps aux | grep ollama`. Cold-load on the first call costs ~15 s; subsequent calls in the same session are warm.

## Measured production numbers (locked after Phase D)

| Metric | Value |
|---|---|
| Steady-state per photo (warm gemma4:31b, downsized, side-channel) | **~64.5 s** |
| 1,000 photos | ~18 hours |
| 10,000 photos | **~7.5 days** continuous |
| Vision pre-pass cost | ~0.4–1.2 s (dominated by Ollama time) |
| Quality on 20-photo Phase D sample | 14/20 fully accurate, 6/20 minor cosmetic, 0/20 failures |

## Conventions and gotchas

### `PromptStyle` enum
- `.bare` — no Vision at all (control / debug only)
- `.sideChannel` — Vision runs but findings stay out of the LLM prompt (**DEFAULT**)
- `.hybrid` — Vision findings injected into the LLM prompt (slower, kept for A/B testing)

Don't change the default to `.hybrid` without re-running the repeatability test — see `project_v3_side_channel_validated.md`.

### Prompt format markers
The `bare()` prompt instructs the model to use exactly `DESCRIPTION:` and `TAGS:` (English uppercase, no space before colon). `CaptionParser` is case-insensitive but does NOT currently tolerate French-style `DESCRIPTION :` (space before colon). If you switch the prompt language, also update the parser.

### OCR stop-list
`Pipeline.ocrStopwords` is a bilingual EN+FR set. ADD to it when new junk patterns surface in production; DO NOT remove the French entries — they catch real OCR noise even though the LLM prompt is in English.

### Image orientation
Always load images via `CGImageSource` (see `VisionAnalyzer.loadCGImageWithOrientation` and `ImageDownsizer.downsizedJPEG`). Both bake in EXIF orientation. NSImage-based loading does NOT preserve orientation reliably and was removed for that reason.

### Ollama timing benchmarks
Always check for concurrent runners before measuring: `ps aux | grep "ollama runner"`. A duplicate runner skews timing 2–3×. See `feedback_ollama_timing.md`.

### Generation rate variance
gemma4:31b on Apple Silicon is variable: 0.5–4 tok/s depending on thermal state and concurrent load. Single-shot timings can mislead; benchmark with 3+ runs when comparing prompts or styles.

### `swift build` SourceKit warnings
SourceKit emits "Cannot find type" diagnostics for cross-file references until the package has been built once. Ignore these warnings; trust `swift build -c release` exit status as the source of truth for compilation correctness.

### Phase F.1 findings (locked 2026-04-10) — read before touching PhotoKit/AppleScript code

**NSAppleScript must run on the main thread.** Always wrap in `await MainActor.run { ... }`. Calling from a Swift cooperative thread pool hangs for ~30 s/call due to AppleEvent replies being dispatched to the main thread's CFRunLoop while the calling thread spins in a Carbon-era `WaitNextEvent` fallback. Confirmed via `sample` stack traces. See `project_phase_f1_spike_results.md`.

**Description-only write-back.** Do NOT write to Photos.app's `name` or `keywords` fields. They don't sync to iOS via iCloud. And `whose keywords contains {"X"}` is structurally broken (returns 0 matches). All metadata goes into ONE `description` field: `<LLM prose>. Tags: tag1, tag2, ..., ai:gemma4-v1`. Use `whose description contains "X"` for sentinel filtering.

**`id of media item` format.** Photos.app's AppleScript returns `<UUID>/L0/001` (43 chars). Lookups accept the stripped UUID prefix (36 chars). Use prefix matching (`hasPrefix`) when comparing returned ids against `PHAsset.localIdentifier`-derived uuid prefixes.

## Memory and decision records

Full project decision history is in `~/.claude/projects/-Users-laurentchouinard-claude-photo-snail/memory/`. The `MEMORY.md` index in that directory is auto-loaded into agent context.

Key files:

- `project_v3_side_channel_validated.md` — the architectural decision
- `project_phase_d_quality_assessment.md` — 20-photo sample results
- `project_locale_decision.md` — English/French history
- `project_vision_vs_llm_complementarity.md` — Vision vs LLM analysis
- `project_hybrid_prompt_bias_finding.md` — variance vs bias finding
- `feedback_ollama_timing.md` — benchmarking gotcha
- `project_phase_f_writeback_decision.md` — original Option B rationale (superseded by F.1 results)
- `project_phase_f1_spike_results.md` — **Phase F.1 spike findings: MainActor, description-only, id format** (2026-04-10)

Read the relevant memory file before changing anything those files cover. Don't relitigate decisions without re-running their original validation tests.

## What NOT to do

- Don't add features not yet planned in `TODO.md` without checking with the user first
- Don't switch the default `PromptStyle` away from `.sideChannel` without a fresh repeatability test
- Don't merge Vision classification labels into the tag set — they leak generic terms (`structure`, `mammal`, `wood_processed`). That's why side-channel exists.
- Don't drop the OCR stop-list, even partially, without observing the regression empirically
- Don't switch from `gemma4:31b` to `gemma4:latest` without re-running the spatial-accuracy test on a representative sample
- Don't write to original photo files yet — Phase F writes to Photos.app's `description` field only via AppleScript
- Don't introduce new image-loading paths that don't bake in EXIF orientation
- Don't trust single-shot LLM timings — benchmark with 3+ runs and verify Ollama isn't double-loaded
- Don't call NSAppleScript from any thread other than the main thread / MainActor — see Phase F.1 findings above
- Don't write to Photos.app's `name` or `keywords` fields — they don't sync to iOS and `whose keywords contains` is broken
- Don't use `whose keywords contains` for sentinel filtering — use `whose description contains` instead
- Don't compare Photos.app's `id of media item` result with exact equality — it returns `<UUID>/L0/001`, use prefix matching
