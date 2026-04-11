import Foundation

/// Persistent SQLite-backed queue for photo processing.
///
/// The queue is the resilience layer for multi-day batch runs. It survives process restarts
/// by sweeping any `in_progress` rows back to `pending` on init, and bounds retries on
/// transient failures (the worker checks `Claim.attempts` against its retry cap).
///
/// Schema (matches the TODO Phase E spec exactly):
///   assets(id, status, attempts, error, processed_at, description, tags_json)
///
/// Status transitions:
///   pending → in_progress  (claimNext, atomic; bumps attempts)
///   in_progress → done     (markDone)
///   in_progress → pending  (recordRetry, transient failure to be retried)
///   in_progress → failed   (markFailed, terminal)
///   in_progress → pending  (init resume sweep, after a crash)
public actor AssetQueue {

    public struct Claim: Sendable {
        public let id: String
        /// Post-bump attempt count: 1 on first try, 2 on first retry, 3 on second retry, etc.
        public let attempts: Int
    }

    public struct FailedRow: Sendable {
        public let id: String
        public let error: String
        public let attempts: Int
    }

    public struct Stats: Sendable {
        public let pending: Int
        public let inProgress: Int
        public let done: Int
        public let failed: Int

        public var total: Int { pending + inProgress + done + failed }
    }

    /// `~/Library/Application Support/photo-snail/queue.sqlite`
    public static var defaultDBPath: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("photo-snail", isDirectory: true)
            .appendingPathComponent("queue.sqlite")
    }

    private let db: SQLiteDB
    private let encoder: JSONEncoder

    public init(dbPath: URL) throws {
        // Ensure the parent directory exists.
        let parent = dbPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        self.db = try SQLiteDB(path: dbPath.path)
        self.encoder = JSONEncoder()

        // Schema. The PRIMARY KEY is the file path (Phase E) or PHAsset.localIdentifier (Phase F).
        try db.exec("""
            CREATE TABLE IF NOT EXISTS assets (
              id           TEXT PRIMARY KEY,
              status       TEXT NOT NULL,
              attempts     INTEGER NOT NULL DEFAULT 0,
              error        TEXT,
              processed_at INTEGER,
              description  TEXT,
              tags_json    TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_assets_status ON assets(status);
            """)

        // WAL mode for crash safety. Set after schema so an empty new DB still flips into WAL.
        try db.exec("PRAGMA journal_mode = WAL;")

        // Resume sweep: anything left in_progress from a crashed run goes back to pending.
        // attempts is preserved — rows that already burned attempts still respect the cap.
        try db.exec("UPDATE assets SET status = 'pending' WHERE status = 'in_progress';")
    }

    /// Idempotent batch insert. Existing rows are not disturbed.
    public func enqueue(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            let stmt = try db.prepare("INSERT OR IGNORE INTO assets (id, status, attempts) VALUES (?, 'pending', 0)")
            defer { stmt.finalize() }
            for id in ids {
                try stmt.bind(id, at: 1)
                _ = try stmt.step()
                try stmt.reset()
            }
        }
    }

    /// Atomically claim the lowest-rowid pending row: bump attempts, set status='in_progress',
    /// stamp processed_at. Returns nil if there are no pending rows.
    public func claimNext() throws -> Claim? {
        var result: Claim? = nil
        try db.transaction {
            let select = try db.prepare("SELECT id, attempts FROM assets WHERE status = 'pending' ORDER BY rowid LIMIT 1")
            defer { select.finalize() }
            guard try select.step() == .row, let id = select.columnText(0) else {
                return
            }
            let newAttempts = select.columnInt(1) + 1

            let update = try db.prepare("UPDATE assets SET status = 'in_progress', attempts = ?, processed_at = ? WHERE id = ?")
            defer { update.finalize() }
            try update.bind(newAttempts, at: 1)
            try update.bind(Self.now(), at: 2)
            try update.bind(id, at: 3)
            _ = try update.step()

            result = Claim(id: id, attempts: Int(newAttempts))
        }
        return result
    }

    /// Transient failure: row goes back to pending so the next claimNext re-picks it.
    /// `attempts` is NOT touched — it was bumped by claimNext.
    public func recordRetry(_ id: String, error: PhotoSnailError) throws {
        let stmt = try db.prepare("UPDATE assets SET status = 'pending', error = ?, processed_at = ? WHERE id = ?")
        defer { stmt.finalize() }
        try stmt.bind(error.shortMessage, at: 1)
        try stmt.bind(Self.now(), at: 2)
        try stmt.bind(id, at: 3)
        _ = try stmt.step()
    }

    /// Successful completion: persist description and merged tags, clear any prior error.
    public func markDone(_ id: String, result: PipelineResult) throws {
        let tagsJSON: String
        do {
            let data = try encoder.encode(result.mergedTags)
            tagsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            tagsJSON = "[]"
        }

        let stmt = try db.prepare("UPDATE assets SET status = 'done', error = NULL, processed_at = ?, description = ?, tags_json = ? WHERE id = ?")
        defer { stmt.finalize() }
        try stmt.bind(Self.now(), at: 1)
        try stmt.bind(result.caption.description, at: 2)
        try stmt.bind(tagsJSON, at: 3)
        try stmt.bind(id, at: 4)
        _ = try stmt.step()
    }

    /// Mark an asset as done during sentinel bootstrap (no PipelineResult available).
    /// Used when Photos.app already has the sentinel in the description from a prior run.
    public func markBootstrapped(_ id: String) throws {
        let stmt = try db.prepare("UPDATE assets SET status = 'done', processed_at = ? WHERE id = ? AND status = 'pending'")
        defer { stmt.finalize() }
        try stmt.bind(Self.now(), at: 1)
        try stmt.bind(id, at: 2)
        _ = try stmt.step()
    }

    /// Terminal failure: row stays as `failed` until manually re-queued (Phase G concern).
    public func markFailed(_ id: String, error: PhotoSnailError) throws {
        let stmt = try db.prepare("UPDATE assets SET status = 'failed', error = ?, processed_at = ? WHERE id = ?")
        defer { stmt.finalize() }
        try stmt.bind(error.shortMessage, at: 1)
        try stmt.bind(Self.now(), at: 2)
        try stmt.bind(id, at: 3)
        _ = try stmt.step()
    }

    /// List all failed rows with their error messages, most recent first.
    public func listFailed() throws -> [FailedRow] {
        let stmt = try db.prepare("SELECT id, error, attempts FROM assets WHERE status = 'failed' ORDER BY processed_at DESC")
        defer { stmt.finalize() }
        var results: [FailedRow] = []
        while try stmt.step() == .row {
            results.append(FailedRow(
                id: stmt.columnText(0) ?? "",
                error: stmt.columnText(1) ?? "",
                attempts: Int(stmt.columnInt(2))
            ))
        }
        return results
    }

    /// Re-queue a failed asset for another attempt. Resets attempts to 0.
    public func requeueFailed(_ id: String) throws {
        let stmt = try db.prepare("UPDATE assets SET status = 'pending', attempts = 0, error = NULL WHERE id = ? AND status = 'failed'")
        defer { stmt.finalize() }
        try stmt.bind(id, at: 1)
        _ = try stmt.step()
    }

    /// Read-only snapshot of all pending row IDs in rowid order.
    /// Used by dry-run mode to iterate pending photos without mutating the
    /// queue. Pair with `DryRunCursor` for the worker-side iteration.
    /// Safe to call repeatedly — no SELECT/UPDATE side effects.
    public func peekAllPendingIds() throws -> [String] {
        let stmt = try db.prepare("SELECT id FROM assets WHERE status = 'pending' ORDER BY rowid")
        defer { stmt.finalize() }
        var ids: [String] = []
        while try stmt.step() == .row {
            if let id = stmt.columnText(0) {
                ids.append(id)
            }
        }
        return ids
    }

    public func stats() throws -> Stats {
        var counts: [String: Int] = [:]
        let stmt = try db.prepare("SELECT status, COUNT(*) FROM assets GROUP BY status")
        defer { stmt.finalize() }
        while try stmt.step() == .row {
            if let status = stmt.columnText(0) {
                counts[status] = Int(stmt.columnInt(1))
            }
        }
        return Stats(
            pending:    counts["pending"] ?? 0,
            inProgress: counts["in_progress"] ?? 0,
            done:       counts["done"] ?? 0,
            failed:     counts["failed"] ?? 0
        )
    }

    private static func now() -> Int64 {
        return Int64(Date().timeIntervalSince1970)
    }
}

/// Iterator over a snapshot of pending asset IDs for dry-run mode.
///
/// The point of this type is to keep the queue completely untouched during a
/// dry-run: no `claimNext` (no `in_progress` flips), no `markDone`, no
/// `markFailed`. The worker pulls IDs from this in-memory cursor, runs the
/// pipeline, prints the result, and moves on. The next real run sees the
/// queue exactly as it was before the dry-run.
///
/// Concurrency: every `next()` call is fully atomic in the actor — there's no
/// internal `await`, so even if multiple workers race, each gets a unique ID.
public actor DryRunCursor {
    private let ids: [String]
    private var index: Int = 0

    public init(ids: [String]) {
        self.ids = ids
    }

    /// Pull the next ID, or nil when the snapshot is exhausted.
    public func next() -> String? {
        guard index < ids.count else { return nil }
        let id = ids[index]
        index += 1
        return id
    }

    public var totalCount: Int { ids.count }
    public var consumedCount: Int { index }
}
