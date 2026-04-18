# PhotoSnail v0.1.4

UI polish release focused on the inspector and photo preview. No pipeline or provider changes.

## What's new

### Denser, cleaner inspector

- **Hero photo capped at 140pt tall** with `.fill` cropping, so portrait photos stop stealing vertical space. Click the hero to open the full-screen preview.
- **Identity and Processing sections rebuilt as inline Grid tables** — label | value | label | value per row, with long values (File, Model, Sentinel, Location, Albums, Asset ID, timestamps) spanning the full row. Unified compact typography across both sections; no more ragged half-columns.
- **Vision classifications** moved to a 2-column layout with inline percentages (`office 87%`) instead of per-label progress bars.
- **Tag pills shrunk** (13→12pt, tighter padding) so more tags fit per row.
- **Per-photo timing** now surfaces as an inline caption (`■ Vision 0.6s · ■ LLM 9.8s · ■ Other 0.1s`) instead of a solid-color TimingBar that read as one block once LLM time dominated.

### Full-screen preview with zoom and pan

The preview sheet (triggered by Space, double-clicking a thumbnail, or clicking the inspector hero) now uses a new `ZoomablePhotoView`:

- **Pinch-to-zoom** on trackpad via `MagnificationGesture` (clamped 1×–10×).
- **Drag-to-pan** when zoomed in.
- **Double-click** toggles between fit and 2.5×.
- **Scroll-wheel zoom** for users without a trackpad, via an `NSEvent` local monitor.
- Spring-back animation if the user pinches under 1×.

### Library interactions

- **Double-click a thumbnail** in the library grid now opens the full-screen preview (was Space-only before). Single-click still selects as usual, and ⌘/⇧-click still toggle/extend.
- **Sidebar Failed filter icon** is red only when `failedCount > 0`; grey otherwise. The eye is drawn to failures when they actually exist.

## Upgrading

Drop-in replacement. No queue DB or settings migrations. Your sentinels, custom prompts, and per-family configs are untouched.

## Internal

- New `ZoomablePhotoView` in `Sources/PhotoSnailGUI/LibraryWindow.swift`.
- Inspector grid/pair helpers in `Sources/PhotoSnailGUI/LibraryInspector.swift` (`kvLabel`, `kvValue`, `timingBreakdownLine`).
- Two new localization keys (`label.vision`, `label.other`) in English — all other languages fall back via the English default path in `Localizer.t(_:)`.
