# sample/

Drop test images here (`.heic`, `.jpg`, `.png`) to exercise the pipeline locally.

This directory's contents are gitignored — the folder and this README are kept so you have an obvious place to put test photos without polluting the repo with personal images.

## Usage

```bash
.build/release/photo-snail-cli sample/IMG_0611.HEIC
.build/release/photo-snail-cli --json sample/*.HEIC
```

For the full Photos library processor, you don't need anything in this folder — `photo-snail-app` reads directly from your macOS Photos library via PhotoKit.
