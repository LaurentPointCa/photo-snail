import Foundation

// MARK: - Log entry

struct LogEntry: Identifiable {
    let id: UInt64
    let timestamp: Date
    let level: LogLevel
    let message: String
    let assetId: String?
}

enum LogLevel: String, CaseIterable, Identifiable {
    case info
    case success
    case warning
    case error

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .info:    return "●"
        case .success: return "✓"
        case .warning: return "▲"
        case .error:   return "✕"
        }
    }
}

// MARK: - Log store

@Observable
@MainActor
final class LogStore {
    static let shared = LogStore()

    private static let maxEntries = 10_000
    private var nextId: UInt64 = 0

    private(set) var entries: [LogEntry] = []
    var detailed: Bool = true

    var filteredEntries: [LogEntry] {
        if detailed { return entries }
        return entries.filter { $0.level != .info }
    }

    func append(_ level: LogLevel, _ message: String, assetId: String? = nil) {
        let entry = LogEntry(
            id: nextId,
            timestamp: Date(),
            level: level,
            message: message,
            assetId: assetId
        )
        nextId += 1
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    private init() {}
}
