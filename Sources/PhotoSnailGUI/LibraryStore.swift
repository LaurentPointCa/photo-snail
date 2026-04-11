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
    /// active-tag chips) will layer on top of this in Phase 4.
    enum Filter: Hashable {
        case all
        case tagged
        case untouched
        case pending
        case failed
    }

    // MARK: - Observable state

    var filter: Filter = .all
    var selection: String? = nil
    var loadError: String? = nil
    var isLoading: Bool = false

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

        rebuildDisplayOrder()
    }

    // MARK: - Filter

    func setFilter(_ f: Filter) {
        guard filter != f else { return }
        filter = f
        rebuildDisplayOrder()
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
        // Rebuilding displayOrder on every change is the simple path. At 10k
        // entries the rebuild is still a few ms. If this becomes a bottleneck
        // during an active run (worker emits ~1 event per ~65 s, plus any
        // GUI edits), Phase 7 can switch to incremental patches.
        rebuildDisplayOrder()
    }

    // MARK: - Filter evaluation

    private func rebuildDisplayOrder() {
        // Display newest-first. `assetIds` is creationDate-ascending from the
        // fetch, so reverse at filter time. (Lazy reversal via `.reversed()`
        // on Arrays is O(1) — it just swaps indices.)
        let ordered = assetIds.reversed()
        switch filter {
        case .all:
            displayOrder = Array(ordered)
        case .tagged:
            displayOrder = ordered.filter { id in
                guard let r = rows[id] else { return false }
                return r.status == "done" && (r.description?.isEmpty == false)
            }
        case .pending:
            displayOrder = ordered.filter { id in
                guard let r = rows[id] else { return false }
                return r.status == "pending" || r.status == "in_progress"
            }
        case .failed:
            displayOrder = ordered.filter { id in
                guard let r = rows[id] else { return false }
                return r.status == "failed"
            }
        case .untouched:
            displayOrder = ordered.filter { rows[$0] == nil }
        }
    }

    // No explicit teardown: the subscription task holds `[weak self]`, and
    // the queue is owned solely by this store, so dropping the store tears
    // down the whole chain (queue → stream → for-await → task) without
    // requiring a nonisolated deinit to poke main-actor state.
}
