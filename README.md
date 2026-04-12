# Photo Snail

**Local-first AI that describes and tags every photo in your macOS Photos library.** No cloud, no upload — your photos never leave your Mac.

Photo Snail runs a vision-language model on your machine, generates a 2–3 sentence description plus 5–15 tags for each photo, and writes the result back to the asset's `description` field in Photos.app. iCloud syncs the description to your other devices, so the new metadata becomes searchable in Photos and Spotlight everywhere.

![Photo Snail](docs/screenshot-annotated.png)

## Why "Snail"?

It's slow on purpose. ~65 seconds per photo on Apple Silicon. A 10,000-photo library takes about a week of background processing. The trade-off is quality: descriptions are accurate, specific, and actually useful — not the generic "outdoor scene with people" you get from off-the-shelf classifiers. Run it overnight, run it for a week, run it while you sleep. Your photos aren't going anywhere.

## Features

- **Fully on-device by default.** Apple Vision + a local LLM via [Ollama](https://ollama.com). No API keys, no rate limits, no privacy concessions.
- **Specific descriptions.** "A black cat sitting on a Sonos speaker next to a white cat" — not "two animals indoors."
- **Searchable tags.** 5–15 lowercase tags per photo, including brands and named objects when visible.
- **Writes back to Photos.app.** Uses AppleScript to populate the `description` field — iCloud syncs it to your iPhone, iPad, and Spotlight.
- **Resilient.** SQLite-backed queue survives restarts, sleep/wake, and crashes. Re-running on a processed library is a no-op.
- **Configurable Ollama.** Default targets `localhost:11434`, but you can point at a remote Ollama instance, an HTTPS proxy, or a setup behind Bearer / Basic / `X-API-Key` auth. Runs against any vision-capable Ollama model you can pick from a list.
- **Per-model sentinels.** Switch models and the tool proposes a matching sentinel (`ai:<family>-v1`) so re-runs across models stay distinguishable, or keep the existing one if you'd rather mix.
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

Photo Snail needs a vision-capable LLM running locally. The recommended setup:

1. Install [Ollama](https://ollama.com) — download the macOS app from their site
2. Launch Ollama (it runs in the menu bar)
3. Pull the recommended model:
   ```bash
   ollama pull gemma4:31b
   ```
   This downloads ~19 GB. Smaller models like `gemma4:latest` (~9.6 GB) are faster but produce lower-quality descriptions.

### 2. Install Photo Snail

1. Download `PhotoSnail-1.0-arm64.zip` from the [latest release](https://github.com/LaurentPointCa/photo-snail/releases/latest)
2. Unzip the archive
3. Drag `PhotoSnail.app` into your `/Applications` folder
4. **First launch:** the app is not notarized, so macOS will block it. Right-click (or Control-click) the app and select **Open**, then click **Open** in the dialog to approve it. You only need to do this once.
5. Grant Photos access when prompted

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

Click **Start**. Grant Photos access when prompted (`System Settings > Privacy & Security > Photos`). Photo Snail will enumerate your library, queue everything, and start processing. The dashboard shows the current photo, the most recently completed photo with its description and tags, throughput, ETA, and any failures.

You can pause and resume at any time. Closing the window does not stop processing — quit from the menu bar to fully exit.

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

Photo Snail is designed to be a privacy maximalist's photo tagger:

- **No network calls** beyond `localhost:11434` (Ollama). The pipeline does not phone home, does not upload images, does not log telemetry.
- **No cloud APIs** in the default path. Cloud vision-LLMs were considered and rejected as the default — see [`CLAUDE.md`](CLAUDE.md) for the rationale.
- **The only thing leaving your Mac** is the description text iCloud syncs to your other Apple devices via the normal Photos sync.

Verify yourself: `ollama` runs locally, the binary makes no other outbound connections, and there's no analytics SDK linked anywhere.

## Project status

Phases A–J complete:

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
