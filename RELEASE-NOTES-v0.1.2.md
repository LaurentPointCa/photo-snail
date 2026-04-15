# PhotoSnail v0.1.2

Tester-feedback follow-up release. Reworks queue semantics around explicit user
intent, stops clobbering pre-existing photo descriptions, and adds the polish
that came out of the first external test on a 39,406-photo library.

## What's new

### Queue semantics

- **Queue starts empty on first launch.** No more auto-enrolling the entire
  library when you click Start. Two ways to fill it:
  - **Add all unprocessed to queue** (header button on the All / Untouched
    library views) — runs the sentinel bootstrap to skip already-processed
    photos and queues the rest.
  - **Add to queue** (selection action) — adds just your selected photos.
    If they were already processed, they get re-queued.
- **Process now** — single-selection action that runs that one photo
  immediately (jumping ahead of anything pending) and pauses. No more
  "click Reprocess, click Start, hit Pause after 1 photo" dance.
- **Remove from queue** + **Clear queue** — new actions on the Queue view.
  Both delete only `pending` rows; `done` / `failed` / `in_progress` are
  preserved so the historical record and the worker's in-flight claim stay
  intact.
- **Re-Process button removed.** Adding an already-processed photo to the
  queue *is* re-processing — one action, not two.

### Don't clobber user data

- **Existing descriptions are preserved.** If a photo has a caption you
  wrote (and it doesn't contain a PhotoSnail sentinel), PhotoSnail keeps
  your text and appends its own description after a `\n\n---\n\n`
  separator. Only overwrites freely when the existing text was written
  by PhotoSnail.

### Startup hygiene

- **Ollama preflight at startup.** GUI surfaces a blocking sheet with
  copy-paste fix commands when Ollama is unreachable or the configured
  model isn't pulled. Includes a one-click **Start Ollama** button that
  runs `open -a Ollama` and re-runs the check. CLI exits 2 with the same
  fixes printed to stderr.
- **Off-main library enumeration.** PhotoKit walks no longer freeze the
  UI on large libraries. Status line reads "Loading data from Photos.app…"
  while the work happens on a background task.

### Doesn't hog your Mac

- **Ollama process priority lowered during batches.** PhotoSnail runs
  `renice +10` on every Ollama-related PID at batch start (no sudo
  required for processes you own). Restored on any worker exit path.
  Browser, editor, and other apps stay responsive while the batch grinds.
- **Auto-start when Mac is locked** — opt-in toggle below the primary
  button. When on, the queue starts on screen lock and pauses on unlock.
  Useful for desktops left running for weeks.

### UI polish

- **Pause shows "Waiting to finish…"** the moment you click it, with a
  spinner — until the in-flight photo's write-back actually completes
  and the worker transitions to paused. No more rage-clicking Pause.
- **Pause button has a working spinner** while a photo is being processed,
  so the running state reads as "actively working."
- **Auto-start-when-locked armed:** Start button replaced by a disabled
  "🔒 Waiting for lock…" so it's clear the watcher will fire it.
- **"Start Queue"** instead of "Start" (matches the queue noun used
  elsewhere). **"Queue"** instead of "Pending" in the sidebar filter and
  navigation title. **"Erase description"** instead of "Clear" for the
  bulk action — and it's hidden from the Queue view since pending photos
  don't have descriptions to erase.
- **Selection clears when switching library filters.** A selection that
  meant something on one filter rarely means anything on another.
- **"Add all unprocessed to queue"** only renders on the All / Untouched
  views — hidden on Tagged / Queue / Failed where it doesn't make sense.
- **Standardized on "PhotoSnail"** (one word) everywhere across the UI,
  README, install script output, and About box.

### Localization

- All new strings translated across **8 languages** (English, French,
  Spanish, German, Portuguese, Japanese, Simplified Chinese, Korean).
- Renamed values for `button.start`, `filter.pending`, `legend.pending`
  swept across all locales.

## Bug fixes

- **Remove from queue / Clear queue now actually update the UI.** The
  AssetQueue broadcast was correctly firing `.updated` events for
  deleted ids, but `LibraryStore.applyChange` only patched the row cache
  when `fetchRow` returned a row — so deleted rows kept showing in the
  Queue view forever and `pendingCount` kept counting them. Cache now
  drops the entry when fetch returns nil after `.inserted` / `.updated`.

## Internal

- AssetQueue schema bumped to **v3** with a `priority` column. `claimNext`
  orders by `priority DESC, rowid` so Process-now rows jump ahead of
  FIFO. Migration is additive — existing v2 databases auto-upgrade.
- New core types: `OllamaClient.PreflightResult`,
  `OllamaPriorityManager.Entry`, `ProcessingEngine.PreflightStatus`.
- New core helpers: `Sentinel.containsAnySentinel(_:)`,
  `OllamaClient.preflight(model:)`, `OllamaClient.tryStartLocalOllama()`,
  `AssetQueue.{addOrRequeue, processNow, removeFromQueue, clearQueue}`,
  `Pipeline.formatDescription(existingDescription:)`,
  `PhotosScripter.readDescription(uuid:)`,
  `LockWatcher`, `OllamaPriorityManager`.
- New `Tests/PhotoSnailCoreTests` target with 11 unit tests covering
  the sentinel matcher and the description-preservation policy.

## Upgrading

Just install over the previous version. The queue DB at
`~/Library/Application Support/photo-snail/queue.sqlite` migrates
automatically from v2 → v3.

If you delete the DB to get the fresh-install experience, the queue
will start empty (no auto-enroll), and you'll click **Add all
unprocessed to queue** to fill it.
