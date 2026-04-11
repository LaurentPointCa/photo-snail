import Foundation

/// Persistent SQLite-backed queue for photo processing.
///
/// The queue is the resilience layer for multi-day batch runs. It survives process restarts
/// by sweeping any `in_progress` rows back to `pending` on init, and bounds retries on
/// transient failures (the worker checks `Claim.attempts` against its retry cap).
///
/// Schema, schema_version = 1:
///   assets(
///     id, status, attempts, error, processed_at, description, tags_json,
///     -- Added in v1 (Library revamp) for the inspector's processing-provenance section:
///     model,        -- Exact Ollama tag used, e.g. "gemma4:31b"
///     sentinel,     -- Sentinel string written to Photos.app description, e.g. "ai:gemma4-v1"
///     vision_json,  -- Serialized VisionFindings (side-channel metadata)
///     vision_ms,    -- Vision pre-pass wall time in ms
///     ollama_ms,    -- Ollama generation wall time in ms
///     total_ms,     -- End-to-end pipeline wall time in ms
///     updated_at    -- Last time the row was mutated (edit tracking)
///   )
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

    /// Full-row projection for the library view and inspector. All fields after
    /// `tagsJson` are nullable because (a) they're only populated on `done` rows,
    /// and (b) pre-v1 rows that existed before the schema migration stay NULL
    /// until the photo is re-processed.
    public struct Row: Sendable {
        public let id: String
        public let status: String
        public let attempts: Int
        public let error: String?
        public let processedAt: Int64?
        public let description: String?
        public let tags: [String]
        public let model: String?
        public let sentinel: String?
        public let visionJSON: String?
        public let visionMs: Int?
        public let ollamaMs: Int?
        public let totalMs: Int?
        public let updatedAt: Int64?
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

    /// Current schema version. Bumped to 1 for the library-revamp columns.
    /// Incrementing this again in the future means writing a new migration
    /// branch in `migrateIfNeeded`.
    public static let currentSchemaVersion: Int64 = 1

    private let db: SQLiteDB
    private let encoder: JSONEncoder

    public init(dbPath: URL) throws {
        // Ensure the parent directory exists.
        let parent = dbPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Pre-migration backup: if the file exists and is still at v0, snapshot it
        // before we touch the schema. Runs before we open `self.db` so the copy is
        // clean of our connection. Idempotent across subsequent opens (once
        // user_version hits 1 we never back up again).
        if FileManager.default.fileExists(atPath: dbPath.path) {
            try Self.backupIfPreV1(dbPath: dbPath)
        }

        self.db = try SQLiteDB(path: dbPath.path)
        self.encoder = JSONEncoder()

        // Base schema (unchanged; matches pre-v1 layout). IF NOT EXISTS means fresh
        // installs get the old layout and then immediately march through migrations.
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

        // Schema migrations. Must run before any queries that reference new columns.
        // Kept as a static helper so it can be called from the actor's nonisolated init.
        try Self.migrateIfNeeded(db: db)

        // Resume sweep: anything left in_progress from a crashed run goes back to pending.
        // attempts is preserved — rows that already burned attempts still respect the cap.
        try db.exec("UPDATE assets SET status = 'pending' WHERE status = 'in_progress';")
    }

    // MARK: - Schema migration

    /// Reads `PRAGMA user_version`, walks each migration branch up to
    /// `currentSchemaVersion`, bumps the version at the end of each branch.
    /// Safe to call on an already-migrated DB (no-op).
    ///
    /// Static (rather than an actor-isolated instance method) so the actor's
    /// nonisolated `init` can call it without a concurrency violation.
    private static func migrateIfNeeded(db: SQLiteDB) throws {
        let current = try readUserVersion(db: db)
        if current >= currentSchemaVersion { return }

        // v0 → v1: add the library-revamp columns. All additions are NULLable so
        // existing rows stay valid without a backfill.
        if current < 1 {
            try db.transaction {
                try db.exec("ALTER TABLE assets ADD COLUMN model        TEXT;")
                try db.exec("ALTER TABLE assets ADD COLUMN sentinel     TEXT;")
                try db.exec("ALTER TABLE assets ADD COLUMN vision_json  TEXT;")
                try db.exec("ALTER TABLE assets ADD COLUMN vision_ms    INTEGER;")
                try db.exec("ALTER TABLE assets ADD COLUMN ollama_ms    INTEGER;")
                try db.exec("ALTER TABLE assets ADD COLUMN total_ms     INTEGER;")
                try db.exec("ALTER TABLE assets ADD COLUMN updated_at   INTEGER;")
            }
            // Bump user_version outside the transaction. The DB is now at v1.
            try db.exec("PRAGMA user_version = 1;")
        }
    }

    private static func readUserVersion(db: SQLiteDB) throws -> Int64 {
        let stmt = try db.prepare("PRAGMA user_version")
        defer { stmt.finalize() }
        guard try stmt.step() == .row else { return 0 }
        return stmt.columnInt(0)
    }

    /// Snapshot the DB file (+ its `-wal` and `-shm` sidecars) to
    /// `queue.sqlite.pre-v1.backup` before the first v0 → v1 migration.
    /// No-op once the DB is already at v1 — the probe connection checks
    /// user_version and bails out cheaply.
    ///
    /// Runs in `nonisolated static` context so it can execute before the
    /// actor's `self.db` is initialized.
    private static func backupIfPreV1(dbPath: URL) throws {
        // Probe user_version using a short-lived connection. We checkpoint the
        // WAL before the probe goes out of scope so the main DB file contains
        // every row and the backup copy doesn't miss uncommitted-to-main-file
        // content from a previous run.
        let version: Int64
        do {
            let probe = try SQLiteDB(path: dbPath.path)
            let stmt = try probe.prepare("PRAGMA user_version")
            defer { stmt.finalize() }
            if try stmt.step() == .row {
                version = stmt.columnInt(0)
            } else {
                version = 0
            }
            // Fold the WAL into the main file so the copy is complete.
            // Ignore failures — a fresh DB with no WAL yet is fine.
            try? probe.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        // `probe` is dropped at end-of-scope, SQLiteDB.deinit closes the handle.

        if version >= 1 { return }

        let fm = FileManager.default
        let backup = dbPath.deletingLastPathComponent()
            .appendingPathComponent("queue.sqlite.pre-v1.backup")
        let wal = URL(fileURLWithPath: dbPath.path + "-wal")
        let walBackup = URL(fileURLWithPath: backup.path + "-wal")
        let shm = URL(fileURLWithPath: dbPath.path + "-shm")
        let shmBackup = URL(fileURLWithPath: backup.path + "-shm")

        // Idempotent: if a backup already exists (e.g. a prior migration attempt
        // crashed after the backup but before the ALTER TABLE), remove and
        // re-copy. The existence of a pre-v1 backup alongside a v0 DB means we
        // never completed the migration — the latest v0 state is the one that
        // matters.
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        try fm.copyItem(at: dbPath, to: backup)

        if fm.fileExists(atPath: wal.path) {
            if fm.fileExists(atPath: walBackup.path) { try fm.removeItem(at: walBackup) }
            try fm.copyItem(at: wal, to: walBackup)
        }
        if fm.fileExists(atPath: shm.path) {
            if fm.fileExists(atPath: shmBackup.path) { try fm.removeItem(at: shmBackup) }
            try fm.copyItem(at: shm, to: shmBackup)
        }
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

    /// Successful completion: persist description, tags, and the full processing
    /// provenance — exact model, sentinel, Vision findings, per-phase timings.
    /// These populate the inspector's "Processing" and "Vision" sections.
    ///
    /// `sentinel` is passed in rather than derived from `result` because it's
    /// a settings-layer concept, not a pipeline output. Both call sites
    /// (`QueueRunner.run` and `ProcessingEngine.launchWorker`) have it in scope.
    public func markDone(_ id: String, result: PipelineResult, sentinel: String) throws {
        let tagsJSON: String
        do {
            let data = try encoder.encode(result.mergedTags)
            tagsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            tagsJSON = "[]"
        }

        // Serialize Vision findings. On encode failure we still mark the row
        // done — a missing vision_json is a small inspector gap, not a reason
        // to fail the whole batch.
        let visionJSON: String?
        do {
            let data = try encoder.encode(result.vision)
            visionJSON = String(data: data, encoding: .utf8)
        } catch {
            visionJSON = nil
        }

        let visionMs = Int64(result.vision.elapsedSeconds * 1000)
        let ollamaMs = Int64(result.caption.elapsedSeconds * 1000)
        let totalMs  = Int64(result.totalElapsedSeconds * 1000)
        let now = Self.now()

        let stmt = try db.prepare("""
            UPDATE assets SET
              status       = 'done',
              error        = NULL,
              processed_at = ?,
              description  = ?,
              tags_json    = ?,
              model        = ?,
              sentinel     = ?,
              vision_json  = ?,
              vision_ms    = ?,
              ollama_ms    = ?,
              total_ms     = ?,
              updated_at   = ?
            WHERE id = ?
            """)
        defer { stmt.finalize() }
        try stmt.bind(now, at: 1)
        try stmt.bind(result.caption.description, at: 2)
        try stmt.bind(tagsJSON, at: 3)
        try stmt.bind(result.caption.model, at: 4)
        try stmt.bind(sentinel, at: 5)
        if let v = visionJSON {
            try stmt.bind(v, at: 6)
        } else {
            try stmt.bindNull(at: 6)
        }
        try stmt.bind(visionMs, at: 7)
        try stmt.bind(ollamaMs, at: 8)
        try stmt.bind(totalMs, at: 9)
        try stmt.bind(now, at: 10)
        try stmt.bind(id, at: 11)
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

    // MARK: - Library view (Phase UI)

    /// Snapshot every row in the queue, in insertion order. Used by the GUI's
    /// `LibraryStore` to build its in-memory row cache at load time.
    ///
    /// Intentionally projects the full schema including the v1 provenance
    /// columns — the inspector wants every field, and a full-row read over a
    /// 10k-row queue is still <50 ms on an SSD.
    public func fetchAllRows() throws -> [Row] {
        let stmt = try db.prepare("""
            SELECT id, status, attempts, error, processed_at, description, tags_json,
                   model, sentinel, vision_json, vision_ms, ollama_ms, total_ms, updated_at
            FROM assets
            ORDER BY rowid
            """)
        defer { stmt.finalize() }
        var rows: [Row] = []
        while try stmt.step() == .row {
            rows.append(Self.decodeRow(stmt))
        }
        return rows
    }

    /// Fetch one row by id. Returns nil if the row doesn't exist in the queue
    /// (e.g. an asset that hasn't been enumerated yet).
    public func fetchRow(id: String) throws -> Row? {
        let stmt = try db.prepare("""
            SELECT id, status, attempts, error, processed_at, description, tags_json,
                   model, sentinel, vision_json, vision_ms, ollama_ms, total_ms, updated_at
            FROM assets
            WHERE id = ?
            """)
        defer { stmt.finalize() }
        try stmt.bind(id, at: 1)
        guard try stmt.step() == .row else { return nil }
        return Self.decodeRow(stmt)
    }

    /// Commit a user-edited description/tags. Keeps `status = done` and bumps
    /// `updated_at`. Intentionally does NOT touch `model`, `sentinel`,
    /// `vision_json`, or the timing columns — those record the original
    /// generation, not the user's refinement.
    ///
    /// Caller is responsible for the Photos.app write-back via `PhotosScripter`.
    /// This method only updates the queue-side record.
    public func updateDescription(id: String, description: String, tags: [String]) throws {
        let tagsJSON: String
        do {
            let data = try encoder.encode(tags)
            tagsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            tagsJSON = "[]"
        }
        let stmt = try db.prepare("""
            UPDATE assets SET
              description = ?,
              tags_json   = ?,
              updated_at  = ?
            WHERE id = ?
            """)
        defer { stmt.finalize() }
        try stmt.bind(description, at: 1)
        try stmt.bind(tagsJSON, at: 2)
        try stmt.bind(Self.now(), at: 3)
        try stmt.bind(id, at: 4)
        _ = try stmt.step()
    }

    /// Push rows back to pending from any state. Resets attempts to 0 and clears
    /// any prior error so the next `claimNext` re-picks them. Used by the bulk
    /// "Re-process" action.
    ///
    /// Deliberately does NOT wipe `description`, `tags_json`, or the provenance
    /// columns: the old values stay put until the worker actually replaces them
    /// via a fresh `markDone`. If the process crashes mid-reprocess, the stale
    /// description remains in the inspector — acceptable because the sentinel
    /// in Photos.app is still there to keep the next real run idempotent.
    public func requeue(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            let stmt = try db.prepare("UPDATE assets SET status = 'pending', attempts = 0, error = NULL, updated_at = ? WHERE id = ?")
            defer { stmt.finalize() }
            let now = Self.now()
            for id in ids {
                try stmt.bind(now, at: 1)
                try stmt.bind(id, at: 2)
                _ = try stmt.step()
                try stmt.reset()
            }
        }
    }

    /// Wipe all generation data for a row and reset it to pending. Called after
    /// a successful bulk "Clear description" operation — the Photos.app side has
    /// already been cleared via AppleScript, and the queue row should now look
    /// like the asset was never processed.
    public func clearResult(_ id: String) throws {
        let stmt = try db.prepare("""
            UPDATE assets SET
              status       = 'pending',
              attempts     = 0,
              error        = NULL,
              description  = NULL,
              tags_json    = NULL,
              model        = NULL,
              sentinel     = NULL,
              vision_json  = NULL,
              vision_ms    = NULL,
              ollama_ms    = NULL,
              total_ms     = NULL,
              updated_at   = ?
            WHERE id = ?
            """)
        defer { stmt.finalize() }
        try stmt.bind(Self.now(), at: 1)
        try stmt.bind(id, at: 2)
        _ = try stmt.step()
    }

    // MARK: - Row decoding helper

    /// Decodes a prepared SELECT statement that projects every column in the
    /// `Row` struct's declared order. Static so it can be shared between
    /// `fetchAllRows` and `fetchRow`, and so the column-index constants stay
    /// in one place.
    private static func decodeRow(_ stmt: Statement) -> Row {
        // Decode tags JSON. Failure → empty array; a malformed row shouldn't
        // break the library view.
        let tags: [String]
        if let json = stmt.columnText(6),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            tags = decoded
        } else {
            tags = []
        }
        return Row(
            id: stmt.columnText(0) ?? "",
            status: stmt.columnText(1) ?? "pending",
            attempts: Int(stmt.columnInt(2)),
            error: stmt.columnText(3),
            processedAt: Self.nullableInt(stmt, at: 4),
            description: stmt.columnText(5),
            tags: tags,
            model: stmt.columnText(7),
            sentinel: stmt.columnText(8),
            visionJSON: stmt.columnText(9),
            visionMs: Self.nullableInt(stmt, at: 10).map(Int.init),
            ollamaMs: Self.nullableInt(stmt, at: 11).map(Int.init),
            totalMs:  Self.nullableInt(stmt, at: 12).map(Int.init),
            updatedAt: Self.nullableInt(stmt, at: 13)
        )
    }

    /// Read an integer column that may be SQL NULL. The underlying C API
    /// returns 0 for NULL, so we check `columnText` as a presence proxy — the
    /// only integer columns we call this on are also the ones we insert as
    /// NULL when absent, so the heuristic is safe.
    private static func nullableInt(_ stmt: Statement, at index: Int32) -> Int64? {
        // columnText returns nil only when the column is actually SQL NULL
        // (Statement already checks `sqlite3_column_type == SQLITE_NULL`).
        // Using it as a presence probe keeps us from adding a new
        // column-type API on SQLiteDB for this one Phase-1 case.
        if stmt.columnText(index) == nil { return nil }
        return stmt.columnInt(index)
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
