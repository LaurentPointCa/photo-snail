# Photo Snail

**Local-first AI that describes and tags every photo in your macOS Photos library.** No cloud, no upload — your photos never leave your Mac.

Photo Snail runs a vision-language model on your machine, generates a 2–3 sentence description plus 5–15 tags for each photo, and writes the result back to the asset's `description` field in Photos.app. iCloud syncs the description to your other devices, so the new metadata becomes searchable in Photos and Spotlight everywhere.

## Why "Snail"?

It's slow on purpose. ~65 seconds per photo on Apple Silicon. A 10,000-photo library takes about a week of background processing. The trade-off is quality: descriptions are accurate, specific, and actually useful — not the generic "outdoor scene with people" you get from off-the-shelf classifiers. Run it overnight, run it for a week, run it while you sleep. Your photos aren't going anywhere.

## Features

- **Fully on-device.** Apple Vision + a local LLM via [Ollama](https://ollama.com). No API keys, no rate limits, no privacy concessions.
- **Specific descriptions.** "A black cat sitting on a Sonos speaker next to a white cat" — not "two animals indoors."
- **Searchable tags.** 5–15 lowercase tags per photo, including brands and named objects when visible.
- **Writes back to Photos.app.** Uses AppleScript to populate the `description` field — iCloud syncs it to your iPhone, iPad, and Spotlight.
- **Resilient.** SQLite-backed queue survives restarts, sleep/wake, and crashes. Re-running on a processed library is a no-op.
- **Two interfaces.** A SwiftUI dashboard with live photo preview, pause/resume, and a failure inspector — plus a CLI for headless / scripted runs.

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

## Build

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

# Dry-run: pipeline only, no write-back
.build/release/photo-snail-app --dry-run

# Limit to N photos (for testing)
.build/release/photo-snail-app --limit 5
```

The first run requests Photos and Automation permissions. The queue persists at `~/Library/Application Support/photo-snail/queue.sqlite` — you can interrupt and resume freely.

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

Phases A–G complete:

- A. Project plan
- B. Hybrid pipeline scaffold
- C. Validation against test photos
- D. Quality assessment (20-photo sample, 14/20 fully accurate)
- E. SQLite queue + resilience
- F. PhotoKit integration + AppleScript write-back
- G. SwiftUI GUI

Phase H (production polish) is next. See [`TODO.md`](TODO.md) for the full plan and progress.

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
