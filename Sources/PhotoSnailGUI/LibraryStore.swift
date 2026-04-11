import Foundation
import Photos
import PhotoSnailCore

/// In-memory model for the library browser. Holds:
/// - A `PHFetchResult<PHAsset>` of every image in the user's library (lazy)
/// - A dictionary of `AssetQueue.Row` keyed by `PHAsset.localIdentifier`
/// - Filter / selection state
///
/// Live updates come from `AssetQueue.changes()` — we subscribe once at
/// `load()` time and patch the row cache on each yielded event. Counts and
/// filter results are computed on demand from the cache; at 10k rows this is
/// sub-millisecond and keeps the data flow simple.
///
/// Phase 2 scope deliberately omits: search (Phase 4), the inverted tag index
/// (Phase 4), multi-selection (Phase 5), and live runner state (Phase 6).
/// The store APIs are additive so those phases won't churn the call sites.
@Observable
@MainActor
final class LibraryStore {

    /// Base filter applied to the library grid. Compound filters (search,
    /// active-tag chips) layer on top of this.
    enum Filter: Hashable {
        case all
        case tagged
        case untouched
        case pending
        case failed
    }

    /// Tag + count pair for the sidebar's popular-tags list.
    struct TagFrequency: Hashable, Identifiable {
        let tag: String
        let count: Int
        var id: String { tag }
    }

    // MARK: - Observable state

    var filter: Filter = .all
    var selection: String? = nil
    var loadError: String? = nil
    var isLoading: Bool = false

    /// Active tag filters. Empty set = no tag filter applied. Non-empty set
    /// is AND-composed with the base `filter`: a row must contain every tag
    /// in the set to be included. The sidebar's "Active Filters" section
    /// and the inspector's tag chips mutate this set.
    var activeTagFilters: Set<String> = []

    /// Case-insensitive substring search over description + tags. An empty
    /// string disables the filter. Text is matched against the in-memory
    /// row cache only, so untouched photos (no row) are hidden when a
    /// search is active.
    ///
    /// The `didSet` rebuilds `displayOrder` on mutation so the SwiftUI
    /// `.searchable` modifier can bind directly without going through a
    /// helper method — typing in the toolbar search field flows straight
    /// through to the filter without an intermediate view-layer plumbing step.
    var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            rebuildDisplayOrder()
        }
    }

    /// Current sentinel from `Settings`, loaded once at `load()` time and
    /// kept in memory for the session. Used as the fallback sentinel when
    /// saving an edit on a row that doesn't have its own stored sentinel
    /// (i.e. a pre-v1 row that was processed before the schema migration).
    private(set) var currentSentinel: String = Settings.default.sentinel

    /// Inverted tag index: `tag → set of PHAsset.localIdentifier`. Built
    /// from the full row cache at load time and patched by the change
    /// stream. Used by the popular-tags sidebar section and by Phase 5's
    /// bulk tag operations.
    private(set) var tagIndex: [String: Set<String>] = [:]

    /// Top-N tags by frequency within the currently-displayed set
    /// (base filter ∩ active tag filters ∩ search). Recomputed at the
    /// tail of `rebuildDisplayOrder` so the sidebar's popular-tags
    /// section adapts to whatever the user is looking at right now —
    /// cheaper than a stored "global tag histogram" and more useful:
    /// clicking "cat" then reveals "cat's neighbors" like "kitten" and
    /// "window" rather than library-wide generic tags.
    private(set) var popularTags: [TagFrequency] = []

    /// Convenience alphabetically-sorted view of `activeTagFilters` for
    /// stable rendering in the sidebar. `Set` has no order of its own.
    var activeTagFiltersOrdered: [String] {
        activeTagFilters.sorted()
    }

    /// Ordered asset ids as returned by `PHFetchResult`. Source of truth for
    /// total library size. Sorted creation-date ascending at fetch time and
    /// displayed newest-first (reversed at filter time).
    private(set) var assetIds: [String] = []

    /// Queue-side row cache, keyed by `PHAsset.localIdentifier`. Misses are
    /// expected — new photos exist in `assetIds` before they land in the queue.
    private(set) var rows: [String: AssetQueue.Row] = [:]

    /// Result of applying the current `filter` to `assetIds`. Rebuilt whenever
    /// `filter`, `assetIds`, or `rows` changes meaningfully.
    private(set) var displayOrder: [String] = []

    // MARK: - Internals

    private var queue: AssetQueue?
    /// Live-held for lazy PHAsset access later (thumbnail fetch, detail view).
    /// Retained here so the underlying fetch isn't re-evaluated.
    private var fetchResult: PHFetchResult<PHAsset>?
    private var subscriptionTask: Task<Void, Never>? = nil

    init() {}

    // MARK: - Counts (computed; cheap at 10k rows)

    var totalCount: Int { assetIds.count }

    var taggedCount: Int {
        rows.values.reduce(0) { acc, row in
            acc + ((row.status == "done" && (row.description?.isEmpty == false)) ? 1 : 0)
        }
    }

    var pendingCount: Int {
        rows.values.reduce(0) { acc, row in
            acc + ((row.status == "pending" || row.status == "in_progress") ? 1 : 0)
        }
    }

    var failedCount: Int {
        rows.values.reduce(0) { acc, row in
            acc + (row.status == "failed" ? 1 : 0)
        }
    }

    /// Photos with no queue row at all — new assets since the last enumeration,
    /// or assets that never got enumerated. Phase 6's runner dock is what
    /// promotes these to `pending`.
    var untouchedCount: Int {
        var c = 0
        for id in assetIds where rows[id] == nil { c += 1 }
        return c
    }

    // MARK: - Load

    /// One-shot bootstrap: open the queue, request Photos auth, fetch all
    /// image assets, snapshot the full row cache, and subscribe to the change
    /// stream. Safe to call more than once — subsequent calls are no-ops once
    /// the initial load has succeeded.
    func load() async {
        guard queue == nil else { return }
        isLoading = true
        defer { isLoading = false }

        // 0. Load persistent settings for the sentinel fallback used on
        //    description edits. A corrupt or missing file falls back to
        //    `Settings.default` — same policy as the rest of the app.
        if let loaded = try? Settings.load() {
            let runtime = loaded.withEnvOverrides()
            self.currentSentinel = runtime.sentinel
        }

        // 1. Queue (migration runs inside AssetQueue.init if needed)
        let q: AssetQueue
        do {
            q = try AssetQueue(dbPath: AssetQueue.defaultDBPath)
            self.queue = q
        } catch {
            self.loadError = "Queue open failed: \(error)"
            return
        }

        // 2. Subscribe BEFORE fetching the snapshot so events that arrive
        //    during the snapshot are buffered in the stream, not lost.
        let stream = await q.changes()
        subscriptionTask = Task { [weak self] in
            for await change in stream {
                await self?.applyChange(change)
            }
        }

        // 3. Photos authorization. `.limited` also works — the user sees the
        //    subset they granted; assets outside it simply won't be in the
        //    fetch result.
        let authStatus = await PhotoLibrary.requestAuth()
        guard authStatus == .authorized || authStatus == .limited else {
            loadError = "Photos access: \(PhotoLibrary.authStatusLabel(authStatus))"
            return
        }

        // 4. Enumerate all image assets into an ordered id list.
        let fr = PhotoLibrary.fetchAllImageAssets()
        self.fetchResult = fr
        var ids: [String] = []
        ids.reserveCapacity(fr.count)
        fr.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        self.assetIds = ids

        // 5. Snapshot the queue rows.
        do {
            let rowArr = try await q.fetchAllRows()
            var dict: [String: AssetQueue.Row] = [:]
            dict.reserveCapacity(rowArr.count)
            for r in rowArr {
                dict[r.id] = r
            }
            self.rows = dict
        } catch {
            loadError = "Queue read failed: \(error)"
            return
        }

        rebuildTagIndex()
        rebuildDisplayOrder()
    }

    // MARK: - Filter

    func setFilter(_ f: Filter) {
        guard filter != f else { return }
        filter = f
        rebuildDisplayOrder()
    }

    /// Whether a given tag is currently in the active filter set.
    func isTagActive(_ tag: String) -> Bool {
        activeTagFilters.contains(tag)
    }

    /// Add a tag to the filter set. No-op if already present.
    func addTagFilter(_ tag: String) {
        guard !tag.isEmpty, !activeTagFilters.contains(tag) else { return }
        activeTagFilters.insert(tag)
        rebuildDisplayOrder()
    }

    /// Remove a tag from the filter set. No-op if absent.
    func removeTagFilter(_ tag: String) {
        guard activeTagFilters.contains(tag) else { return }
        activeTagFilters.remove(tag)
        rebuildDisplayOrder()
    }

    /// Toggle a tag's membership in the filter set. The primary left-click
    /// action on a tag chip: click to include, click again to exclude.
    func toggleTagFilter(_ tag: String) {
        if activeTagFilters.contains(tag) {
            activeTagFilters.remove(tag)
        } else {
            activeTagFilters.insert(tag)
        }
        rebuildDisplayOrder()
    }

    /// Replace the active tag set with a single tag. Used by the chip
    /// context menu's "View only photos with this tag" option.
    func setSoleTagFilter(_ tag: String) {
        let next: Set<String> = tag.isEmpty ? [] : [tag]
        guard activeTagFilters != next else { return }
        activeTagFilters = next
        rebuildDisplayOrder()
    }

    /// Clear every active tag filter.
    func clearTagFilters() {
        guard !activeTagFilters.isEmpty else { return }
        activeTagFilters.removeAll()
        rebuildDisplayOrder()
    }

    // MARK: - Edits

    /// Commit a user-edited description/tags for a single asset:
    ///   1. Format the Photos.app payload, preserving the row's original
    ///      sentinel (or the current settings sentinel if none stored).
    ///   2. Write back via AppleScript on the main actor.
    ///   3. Update the queue row — the queue broadcasts `.updated(id)`,
    ///      which triggers our subscription and patches `rows[id]`
    ///      automatically.
    ///
    /// Throws on either AppleScript failure or queue-update failure so the
    /// caller can surface the error inline. On success, the store's cache
    /// reflects the new values by the time the `await` returns (the change
    /// stream runs synchronously from broadcast → applyChange).
    func saveDescription(id: String, description: String, tags: [String]) async throws {
        guard let queue = queue else {
            throw PhotoSnailError.imageLoadFailed("Queue is not open")
        }

        // Preserve the row's sentinel if present — the sentinel records
        // which generation produced the original description. An edit is
        // a refinement of that generation, not a new one, so we keep it.
        // Pre-v1 rows with no stored sentinel fall back to the settings
        // sentinel (best available proxy for "what would we write today").
        let sentinel = rows[id]?.sentinel ?? currentSentinel

        let payload = Pipeline.formatDescription(
            description: description,
            tags: tags,
            sentinel: sentinel
        )

        // The enclosing class is @MainActor, so this call is already on the
        // main thread — no `MainActor.run` hop needed. NSAppleScript requires
        // main thread per Phase F.1 findings.
        let uuid = PhotoLibrary.uuidPrefix(id)
        _ = try PhotosScripter.runBatch(uuid: uuid, descriptionPayload: payload)

        // Update the queue row. This broadcasts `.updated(id)`, which our
        // own subscription handles by re-fetching the row and patching the
        // cache — so by the end of this call the displayed row is fresh.
        try await queue.updateDescription(id: id, description: description, tags: tags)
    }

    // MARK: - Change stream handler

    private func applyChange(_ change: AssetQueue.QueueChange) async {
        guard let q = queue else { return }
        switch change {
        case .inserted(let ids):
            // Patch each inserted id. Most will be no-ops (idempotent batch
            // inserts) — the cost is one fetchRow per id and the store
            // reflects whatever is currently persisted.
            for id in ids {
                if let row = try? await q.fetchRow(id: id) {
                    rows[id] = row
                }
            }
        case .updated(let id):
            if let row = try? await q.fetchRow(id: id) {
                rows[id] = row
            }
        }
        // Rebuild the tag index AND the display order. Full-rebuild is the
        // simple path; at 10k rows × ~8 tags it stays sub-ms for each, and
        // change events arrive ~1/minute during a run plus at most a few per
        // second during a bulk edit — easily inside budget. Phase 7 can
        // switch to incremental patches if this shows up in traces.
        rebuildTagIndex()
        rebuildDisplayOrder()
    }

    // MARK: - Filter evaluation

    private func rebuildDisplayOrder() {
        // Display newest-first. `assetIds` is creationDate-ascending from the
        // fetch, so reverse at filter time. (Lazy reversal via `.reversed()`
        // on Arrays is O(1) — it just swaps indices.)
        let ordered = assetIds.reversed()

        let activeTags = activeTagFilters
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSearch = !query.isEmpty

        displayOrder = ordered.filter { id in
            // 1. Base filter (status-based).
            guard matchesBaseFilter(id: id) else { return false }

            // 2. Tag filter (AND). Every active tag must be present on the
            //    row. Untouched rows never match a tag filter (no tags).
            if !activeTags.isEmpty {
                guard let r = rows[id] else { return false }
                for tag in activeTags where !r.tags.contains(tag) {
                    return false
                }
            }

            // 3. Text search (substring). Matches on description OR any tag.
            //    Untouched rows have no description/tags and can't match a
            //    non-empty query.
            if hasSearch {
                guard let r = rows[id] else { return false }
                let descMatch = r.description.map { $0.lowercased().contains(query) } ?? false
                if !descMatch {
                    let tagMatch = r.tags.contains { $0.lowercased().contains(query) }
                    if !tagMatch { return false }
                }
            }

            return true
        }

        rebuildPopularTags()
    }

    private func matchesBaseFilter(id: String) -> Bool {
        switch filter {
        case .all:
            return true
        case .tagged:
            guard let r = rows[id] else { return false }
            return r.status == "done" && (r.description?.isEmpty == false)
        case .pending:
            guard let r = rows[id] else { return false }
            return r.status == "pending" || r.status == "in_progress"
        case .failed:
            guard let r = rows[id] else { return false }
            return r.status == "failed"
        case .untouched:
            return rows[id] == nil
        }
    }

    /// Full rebuild of the inverted tag index from the current row cache.
    /// Called at `load()` time and on every `applyChange` — at 10k rows ×
    /// ~8 tags/row the rebuild is a few ms, well within the "imperceptible"
    /// budget for a change event arriving every ~65 s from the worker.
    private func rebuildTagIndex() {
        var idx: [String: Set<String>] = [:]
        for (id, row) in rows {
            for tag in row.tags {
                idx[tag, default: []].insert(id)
            }
        }
        tagIndex = idx
    }

    /// Recompute the sidebar's popular-tags histogram from the current
    /// `displayOrder`. Scoped to the displayed set (not the full library)
    /// so clicking into a filter produces contextually-relevant suggestions
    /// — filtering by "cat" surfaces "kitten"/"window"/"sunny", not
    /// library-wide generic tags. Excludes already-active filter tags so
    /// the list shows only "what else" rather than what's already applied.
    private func rebuildPopularTags() {
        var counts: [String: Int] = [:]
        for id in displayOrder {
            guard let r = rows[id] else { continue }
            for tag in r.tags {
                counts[tag, default: 0] += 1
            }
        }
        for t in activeTagFilters { counts.removeValue(forKey: t) }
        popularTags = counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(20)
            .map { TagFrequency(tag: $0.key, count: $0.value) }
    }

    // No explicit teardown: the subscription task holds `[weak self]`, and
    // the queue is owned solely by this store, so dropping the store tears
    // down the whole chain (queue → stream → for-await → task) without
    // requiring a nonisolated deinit to poke main-actor state.
}
