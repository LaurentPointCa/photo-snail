import Foundation

/// Renice the local Ollama daemon + runners during a batch so interactive
/// apps (browser, editors) stay responsive while the pipeline grinds.
///
/// macOS lets you renice your own processes UPWARD (higher nice = lower
/// priority) without sudo as long as they run under your uid. Ollama
/// installed via its .pkg / `brew services` runs under the user's uid,
/// so this works without elevation.
///
/// Failures (Ollama not installed, running under a different user, etc.)
/// are silent by design — this is a quality-of-life tweak, not a
/// correctness requirement. The caller receives a list of PIDs + nice
/// deltas that were applied so it can log and restore on batch end.
///
/// Not called automatically; callers opt in when a batch starts and must
/// call `restore(entries:)` when it ends. See `ProcessingEngine.launchWorker`.
public enum OllamaPriorityManager {

    /// Result of one adjustment — the PID that was touched and the nice
    /// value it had BEFORE we changed it, so we can restore later.
    public struct Entry: Sendable {
        public let pid: Int32
        public let previousNice: Int
        public let newNice: Int
    }

    /// Raise the nice value (lower the scheduling priority) of every
    /// Ollama-related process currently running by `delta`. Returns the
    /// list of adjustments for later restoration. Empty on failure.
    @discardableResult
    public static func lower(by delta: Int = 10) -> [Entry] {
        let pids = findOllamaPids()
        var out: [Entry] = []
        for pid in pids {
            guard let current = getpriority(pid) else { continue }
            let target = current + delta
            if setpriority(pid, to: target) {
                out.append(Entry(pid: pid, previousNice: current, newNice: target))
            }
        }
        return out
    }

    /// Undo a previous `lower(by:)` call. Best-effort: a PID that has
    /// since exited (runner subprocess finished a request) is silently
    /// skipped.
    public static func restore(entries: [Entry]) {
        for entry in entries {
            _ = setpriority(entry.pid, to: entry.previousNice)
        }
    }

    // MARK: - Internals

    /// Return PIDs for every process whose command matches "ollama" —
    /// covers both the main daemon and any active `ollama runner`
    /// subprocesses. Uses `pgrep -f ollama` and filters out our own
    /// PID + any `grep`-style false positives defensively.
    private static func findOllamaPids() -> [Int32] {
        let output = runCommand("/usr/bin/pgrep", args: ["-f", "ollama"]) ?? ""
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
            .filter { $0 != ownPid }
    }

    /// `getpriority(2)` wrapper for PID priority reads. Uses the raw BSD
    /// call via Process here instead of the libc function because we want
    /// to scope this file to no new C imports — Swift's `Darwin.getpriority`
    /// works but requires an `import Darwin` that would leak into callers.
    /// Value is macOS's "nice" number (20 for idle, 0 for default,
    /// -20 for highest priority).
    private static func getpriority(_ pid: Int32) -> Int? {
        guard let output = runCommand("/bin/ps", args: ["-o", "nice=", "-p", "\(pid)"]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    /// `renice <value> -p <pid>`. Returns true if the command exited 0.
    private static func setpriority(_ pid: Int32, to nice: Int) -> Bool {
        let (_, status) = runCommandWithStatus("/usr/bin/renice", args: ["\(nice)", "-p", "\(pid)"])
        return status == 0
    }

    @discardableResult
    private static func runCommand(_ path: String, args: [String]) -> String? {
        let (output, status) = runCommandWithStatus(path, args: args)
        return status == 0 ? output : nil
    }

    private static func runCommandWithStatus(_ path: String, args: [String]) -> (String, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return ("", -1)
        }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (out, proc.terminationStatus)
    }
}
