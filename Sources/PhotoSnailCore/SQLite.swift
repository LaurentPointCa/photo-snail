import Foundation
import SQLite3

/// Thin Swift wrapper around the system SQLite3 C module. Just enough surface to support
/// the AssetQueue: open/close, exec, prepare-bind-step, transactions. No prepared-statement
/// caching — the queue runs at ~1 op/min so the overhead is irrelevant.

public enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case execFailed(code: Int32, message: String, sql: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case bindFailed(code: Int32, message: String, index: Int32)
    case stepFailed(code: Int32, message: String)

    public var description: String {
        switch self {
        case .openFailed(let c, let m):
            return "sqlite open failed (\(c)): \(m)"
        case .execFailed(let c, let m, let s):
            return "sqlite exec failed (\(c)): \(m) — sql: \(s)"
        case .prepareFailed(let c, let m, let s):
            return "sqlite prepare failed (\(c)): \(m) — sql: \(s)"
        case .bindFailed(let c, let m, let i):
            return "sqlite bind failed at index \(i) (\(c)): \(m)"
        case .stepFailed(let c, let m):
            return "sqlite step failed (\(c)): \(m)"
        }
    }
}

public enum StepResult {
    case row
    case done
}

public final class SQLiteDB {
    fileprivate var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError.openFailed(code: rc, message: msg)
        }
    }

    deinit {
        if handle != nil {
            sqlite3_close(handle)
        }
    }

    /// Number of rows changed by the most recent INSERT / UPDATE / DELETE
    /// on this connection. Wraps `sqlite3_changes`. Per-statement, not
    /// cumulative — pull it immediately after the step that did the work.
    public func changes() -> Int {
        return Int(sqlite3_changes(handle))
    }

    public func exec(_ sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "unknown"
            if errPtr != nil { sqlite3_free(errPtr) }
            throw SQLiteError.execFailed(code: rc, message: msg, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw SQLiteError.prepareFailed(code: rc, message: msg, sql: sql)
        }
        return Statement(handle: stmt!, owner: self)
    }

    /// Wraps `block` in BEGIN IMMEDIATE / COMMIT, ROLLBACK on throw.
    public func transaction(_ block: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try block()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    fileprivate var errorMessage: String {
        return handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }
}

public final class Statement {
    fileprivate var stmt: OpaquePointer?
    fileprivate weak var owner: SQLiteDB?

    // SQLITE_TRANSIENT is a sentinel #define in sqlite3.h: ((sqlite3_destructor_type)-1)
    // It's not bridged to Swift as a constant, so we reconstruct it.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(handle: OpaquePointer, owner: SQLiteDB) {
        self.stmt = handle
        self.owner = owner
    }

    deinit { finalize() }

    public func bind(_ value: String, at index: Int32) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, Statement.SQLITE_TRANSIENT)
        if rc != SQLITE_OK {
            throw SQLiteError.bindFailed(code: rc, message: owner?.errorMessage ?? "unknown", index: index)
        }
    }

    public func bind(_ value: Int64, at index: Int32) throws {
        let rc = sqlite3_bind_int64(stmt, index, value)
        if rc != SQLITE_OK {
            throw SQLiteError.bindFailed(code: rc, message: owner?.errorMessage ?? "unknown", index: index)
        }
    }

    public func bindNull(at index: Int32) throws {
        let rc = sqlite3_bind_null(stmt, index)
        if rc != SQLITE_OK {
            throw SQLiteError.bindFailed(code: rc, message: owner?.errorMessage ?? "unknown", index: index)
        }
    }

    public func step() throws -> StepResult {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:  return .row
        case SQLITE_DONE: return .done
        default:
            throw SQLiteError.stepFailed(code: rc, message: owner?.errorMessage ?? "unknown")
        }
    }

    public func columnText(_ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    public func columnInt(_ index: Int32) -> Int64 {
        return sqlite3_column_int64(stmt, index)
    }

    public func reset() throws {
        let rc = sqlite3_reset(stmt)
        if rc != SQLITE_OK {
            throw SQLiteError.stepFailed(code: rc, message: owner?.errorMessage ?? "unknown")
        }
    }

    public func finalize() {
        if let s = stmt {
            sqlite3_finalize(s)
            stmt = nil
        }
    }
}
