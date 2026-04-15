# PhotoSnail

**Local-first AI that describes and tags every photo in your macOS Photos library.** No cloud, no upload — your photos never leave your Mac.

PhotoSnail runs a vision-language model on your machine, generates a 2–3 sentence description plus 5–15 tags for each photo, and writes the result back to the asset's `description` field in Photos.app. iCloud syncs the description to your other devices, so the new metadata becomes searchable in Photos and Spotlight everywhere.

![PhotoSnail](docs/screenshot-annotated.png)

## Why "Snail"?

It's slow on purpose. ~65 seconds per photo on Apple Silicon. A 10,000-photo library takes about a week of background processing. The trade-off is quality: descriptions are accurate, specific, and actually useful — not the generic "outdoor scene with people" you get from off-the-shelf classifiers. Run it overnight, run it for a week, run it while you sleep. Your photos aren't going anywhere.

## Features

- **Fully on-device by default.** Apple Vision + a local LLM via [Ollama](https://ollama.com). No API keys, no rate limits, no privacy concessions.
- **Specific descriptions.** "A black cat sitting on a Sonos speaker next to a white cat" — not "two animals indoors."
- **Searchable tags.** 5–15 lowercase tags per photo, including brands and named objects when visible.
- **Writes back to Photos.app.** Uses AppleScript to populate the `description` field — iCloud syncs it to your iPhone, iPad, and Spotlight.
- **Preserves your existing descriptions.** If a photo already has a caption you wrote, PhotoSnail keeps it and appends its own description after a separator. Only overwrites freely when the existing text was written by PhotoSnail (sentinel detection).
- **Explicit queue semantics.** Queue starts empty on first launch. Add photos via "Add all unprocessed to queue" or by selecting and adding. **Process now** runs a single selected photo and stops — no surprise full-library batches.
- **Doesn't hog your Mac.** Lowers Ollama's process priority while a batch runs so the browser, editor, and other apps stay responsive. Optional **Auto-start when Mac is locked** runs the queue only while you're away.
- **Resilient.** SQLite-backed queue survives restarts, sleep/wake, and crashes. Re-running on a processed library is a no-op.
- **Ollama preflight at startup.** GUI surfaces a blocking sheet with copy-paste fix commands (and a one-click Start Ollama button) when Ollama is unreachable or the configured model is missing. CLI exits 2 with the same fixes printed.
- **Configurable Ollama.** Default targets `localhost:11434`, but you can point at a remote Ollama instance, an HTTPS proxy, or a setup behind Bearer / Basic / `X-API-Key` auth. Runs against any vision-capable Ollama model you can pick from a list.
- **Per-model sentinels.** Switch models and the tool proposes a matching sentinel (`ai:<family>-v1`) so re-runs across models stay distinguishable, or keep the existing one if you'd rather mix.
- **Editable prompt.** Tweak the instruction sent to the LLM right from Settings. Changing the prompt automatically bumps the sentinel version so new results stay distinguishable from old ones, and offers to requeue previously-processed photos.
- **8 languages, in-place.** UI switches at runtime between English, French, Spanish, German, Portuguese, Japanese, Simplified Chinese, and Korean — no restart. A language change can also re-point the prompt and queue existing descriptions for translation via a fast text-only pass.
- **Two interfaces.** A SwiftUI dashboard with live photo preview, pause/resume, settings sheet, and a failure inspector — plus a CLI for headless / scripted runs.

## How it works

```
PHAsset (from Photos.app)
  ↓
Downsize to 1024 px JPEG (CGImageSource thumbnail, EXIF baked in)
  ↓
[parallel signals]
  ├─ Apple Vision    classify + animals + faces + OCR  (~1 s)
  └─ Local LLM       prompt + image → description + tags  (~60 s)
  ↓
Tag merge          LLM tags + LLM-confirmed OCR rescue
  ↓
Write back         description field via AppleScript
  ↓
Sentinel marker    so re-runs skip processed photos
```

The pipeline runs Apple Vision as a *side channel*: its findings are not injected into the LLM prompt (that was tested and rejected — see [`CLAUDE.md`](CLAUDE.md) for the rationale). Vision is used only for OCR text rescue and structured metadata; the LLM describes the photo from the bare image alone.

## Requirements

- **macOS 14** (Sonoma) or later, Apple Silicon recommended
- **Swift 5.9+** (Xcode 15 or the Swift toolchain)
- **[Ollama](https://ollama.com)** running locally on the default port (11434)
- A vision-capable model pulled into Ollama. The default is **`gemma4:31b`**:
  ```bash
  ollama pull gemma4:31b
  ```
  Smaller / faster models (e.g. `gemma4:latest`) work but produce lower-quality descriptions — see [`CLAUDE.md`](CLAUDE.md) for the comparison.

## Install

### 1. Set up a local inference model

PhotoSnail needs a vision-capable LLM running locally. The recommended setup:

1. Install [Ollama](https://ollama.com) — download the macOS app from their site
2. Launch Ollama (it runs in the menu bar)
3. Pull the recommended model:
   ```bash
   ollama pull gemma4:31b
   ```
   This downloads ~19 GB. Smaller models like `gemma4:latest` (~9.6 GB) are faster but produce lower-quality descriptions.

### 2. Install PhotoSnail

PhotoSnail is **not signed with an Apple Developer ID** (I chose not to pay Apple's $99/year fee for this personal project), so macOS Gatekeeper will flag it as "damaged" on first launch. The release zip includes `install.sh` to handle that for you.

**Recommended — run the installer:**

1. Download the latest `PhotoSnail-vX.Y.Z-arm64.zip` from the [latest release](https://github.com/LaurentPointCa/photo-snail/releases/latest)
2. Unzip the archive
3. Open Terminal in the unzipped folder and run:
   ```bash
   ./install.sh
   ```
   This strips the macOS quarantine flag, copies `PhotoSnail.app` to `/Applications`, and launches it.
4. Grant Photos access when prompted.

**Manual install** (if you'd rather not run the script):

1. Unzip the archive
2. Drag `PhotoSnail.app` to `/Applications`
3. In Terminal, strip the quarantine flag:
   ```bash
   xattr -cr /Applications/PhotoSnail.app
   ```
4. Double-click the app to launch. Grant Photos access when prompted.

> Note: macOS's old "right-click → Open" workaround stopped working on recent macOS versions for apps downloaded through Chrome, so the `xattr` step is now required regardless of how you install.

## Build from source

```bash
swift build -c release
```

Three binaries land in `.build/release/`:

| Binary | Purpose |
|---|---|
| `photo-snail-cli` | Process individual image files (HEIC/JPEG/PNG). Useful for testing the pipeline on a single photo. |
| `photo-snail-app` | Headless CLI that processes your full macOS Photos library end-to-end. |
| `photo-snail-gui` | SwiftUI dashboard. Live preview, stats, pause/resume, failure inspector. |

To package the GUI as a `.app` bundle:

```bash
./bundle-gui.sh
open .build/release/PhotoSnail.app

# Optional: install to /Applications
cp -R .build/release/PhotoSnail.app /Applications/
```

## Usage

### GUI

```bash
./bundle-gui.sh
open .build/release/PhotoSnail.app
```

On first launch the app does an Ollama preflight check; if Ollama isn't running or the configured model isn't pulled, you get a blocking sheet with the exact `brew install` / `ollama pull` commands and a one-click **Start Ollama** button.

The queue is empty by default. Two ways to fill it:

- **Add all unprocessed to queue** (header button, visible on the All and Untouched library views) — enumerates your library, runs the sentinel bootstrap to skip already-processed photos, and queues the rest.
- **Add to queue** (selection action, when you've selected one or more photos) — adds just those photos. If they're already processed, this re-queues them.

Then click **Start Queue**. Grant Photos access when prompted (`System Settings > Privacy & Security > Photos`). The dashboard shows the current photo, the most recently completed photo with its description and tags, throughput, ETA, and any failures.

Other actions worth knowing:

- **Process now** — single-selection action. Runs that one photo (jumping ahead of anything pending) and pauses. No surprise full-batch start.
- **Pause** — flips to a disabled "Waiting to finish…" label until the in-flight photo completes, then transitions to fully paused. Click again to resume.
- **Auto-start when Mac is locked** — toggle below the primary button. When on, the queue starts on screen lock and pauses on unlock. Useful for desktops left running.
- **Queue view** — sidebar filter that shows only pending photos. The selection action becomes **Remove from queue**, and a **Clear queue** button appears in the header.

While processing, PhotoSnail renices the Ollama daemon to keep your other apps responsive. Closing the window does not stop processing — quit from the menu bar to fully exit.

### CLI — single image

```bash
.build/release/photo-snail-cli /path/to/photo.heic

# JSON output
.build/release/photo-snail-cli --json /path/to/photo.heic

# Use a different Ollama model
.build/release/photo-snail-cli --model gemma4:latest /path/to/photo.heic

# Compare prompting modes
.build/release/photo-snail-cli --bare /path/to/photo.heic     # no Vision pre-pass
.build/release/photo-snail-cli --hybrid /path/to/photo.heic   # Vision injected into prompt (slower)
```

### CLI — full Photos library

```bash
# List the 10 most recent assets (sanity check)
.build/release/photo-snail-app --list 10

# Process the entire library
.build/release/photo-snail-app

# Dry-run: full pipeline, no Photos.app write-back, no queue mutation.
# Safe to run on a real queue — it leaves every row exactly as it was.
.build/release/photo-snail-app --dry-run

# Limit to N photos (for testing)
.build/release/photo-snail-app --limit 5
```

The first run requests Photos and Automation permissions. The queue persists at `~/Library/Application Support/photo-snail/queue.sqlite` — you can interrupt and resume freely.

### CLI — picking a model and configuring Ollama

```bash
# List models installed in Ollama (current marked with *)
.build/release/photo-snail-app --list-models

# Probe Ollama with the current connection config
.build/release/photo-snail-app --ollama-test

# Switch to a different tag of the same family — silent (sentinel unchanged)
.build/release/photo-snail-app --model gemma4:latest

# Switch to a different model family — REQUIRES an explicit sentinel choice
.build/release/photo-snail-app --model llava:13b --sentinel ai:llava-v1
.build/release/photo-snail-app --model llava:13b --keep-sentinel    # mix under one sentinel

# Point at a remote / proxied Ollama
.build/release/photo-snail-app --ollama-url https://ollama.my.lan
.build/release/photo-snail-app --ollama-url https://ollama.my.lan --ollama-key sk-...

# Custom auth headers (Basic, X-API-Key, etc.)
.build/release/photo-snail-app --ollama-header "X-API-Key=..."
.build/release/photo-snail-app --ollama-header "Authorization=Basic dXNlcjpwYXNz"

# Avoid persisting the API key to disk — env var takes precedence at runtime
PHOTO_SNAIL_OLLAMA_API_KEY=sk-... .build/release/photo-snail-app
```

Settings persist to `~/Library/Application Support/photo-snail/settings.json` (file mode `0600`). The API key is stored in plain text there as a deliberate tradeoff — set the `PHOTO_SNAIL_OLLAMA_API_KEY` environment variable instead if you'd rather not persist it. The GUI exposes the same settings via a gear icon in the toolbar.

A model switch that crosses the model family boundary is rejected with exit code `2` and a clear error unless you pass `--sentinel` or `--keep-sentinel` — this prevents a multi-day batch from silently flipping which sentinel is being written into your photos.

## How long will it take?

| Photos | Wall time (warm `gemma4:31b`, side-channel, downsized) |
|---|---|
| 100 | ~1.5 hours |
| 1,000 | ~18 hours |
| 10,000 | ~7.5 days continuous |

Variance is real: the model runs at 0.5–4 tokens/sec depending on thermals and concurrent load. Runs are checkpointed per photo, so you can stop and restart without losing progress.

## Privacy

PhotoSnail is designed to be a privacy maximalist's photo tagger:

- **No network calls** beyond `localhost:11434` (Ollama). The pipeline does not phone home, does not upload images, does not log telemetry.
- **No cloud APIs** in the default path. Cloud vision-LLMs were considered and rejected as the default — see [`CLAUDE.md`](CLAUDE.md) for the rationale.
- **The only thing leaving your Mac** is the description text iCloud syncs to your other Apple devices via the normal Photos sync.

Verify yourself: `ollama` runs locally, the binary makes no other outbound connections, and there's no analytics SDK linked anywhere.

## Project status

Phases A–K complete (current release: **v0.1.2**):

- A. Project plan
- B. Hybrid pipeline scaffold
- C. Validation against test photos
- D. Quality assessment (20-photo sample, 14/20 fully accurate)
- E. SQLite queue + resilience
- F. PhotoKit integration + AppleScript write-back
- G. SwiftUI GUI
- H. Deferred (mid-batch quality review showed no weak-output cluster to rescue)
- I. Visual rehaul — 3-column library browser, inspector, design system
- J. UI polish — bug fixes, UX improvements, log window, About box
- K. Custom prompt editor, 8-language runtime localization, translation pipeline
- L. (v0.1.2) External-tester feedback batch — empty-queue default, Add to Queue / Process now, Remove/Clear queue actions, description preservation, Ollama preflight + Start Ollama button, auto-start when locked, Ollama priority lowered during batches, naming + label cleanup, full 8-locale translation sweep

The CLI and GUI are in production use against the author's full library. See [`TODO.md`](TODO.md) for the phased plan and the parked items under "Potential future improvements".

## Sample images

The `sample/` directory is gitignored. Drop your own `.heic`, `.jpg`, or `.png` files there to test the pipeline locally:

```bash
.build/release/photo-snail-cli sample/IMG_0611.HEIC
```

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — full architecture, design decisions, and gotchas. Read this before making changes.
- [`TODO.md`](TODO.md) — phased plan and progress notes.

## License

MIT — see [`LICENSE`](LICENSE).
