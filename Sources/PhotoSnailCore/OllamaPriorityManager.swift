import Foundation

/// Renice local LLM server processes (Ollama, mlx-vlm, vLLM, LM Studio…)
/// during a batch so interactive apps stay responsive while the pipeline
/// grinds. macOS lets you renice your own processes upward (higher nice =
/// lower priority) without sudo as long as they run under your uid, which
/// covers every locally-hosted server we target.
///
/// Failures (server not installed, running under a different user, etc.)
/// are silent by design — this is a quality-of-life tweak, not a
/// correctness requirement. The caller receives a list of PIDs + nice
/// deltas that were applied so it can log and restore on batch end.
///
/// Not called automatically; callers opt in when a batch starts and must
/// call `restore(entries:)` when it ends. See `ProcessingEngine.launchWorker`.
public enum LLMPriorityManager {

    /// Result of one adjustment — the PID that was touched and the nice
    /// value it had BEFORE we changed it, so we can restore later.
    public struct Entry: Sendable {
        public let pid: Int32
        public let previousNice: Int
        public let newNice: Int
    }

    /// Patterns matched against `ps -f` command lines via `pgrep -f`. Each
    /// provider ships its own preset; callers combine them based on the
    /// active provider. Patterns are intentionally narrow so we don't
    /// renice unrelated Python/Node processes on a busy dev machine.
    public enum ProviderPreset: Sendable {
        case ollama
        case openAICompatible

        /// `pgrep -f` regex fragments. A process matching ANY pattern is
        /// eligible. Each pattern runs as its own `pgrep` invocation and
        /// the results are unioned (deduped) before renicing.
        public var patterns: [String] {
            switch self {
            case .ollama:
                // Covers the main daemon and any transient `ollama runner`
                // subprocesses spawned per request.
                return ["ollama"]
            case .openAICompatible:
                // Covers the three common self-hosted OpenAI-compatible
                // servers. Patterns are specific enough to avoid catching
                // arbitrary Python processes: mlx-vlm runs as
                // `python -m mlx_vlm.server`, vLLM exposes `vllm.entrypoints`
                // or a `vllm` binary, LM Studio ships as `LM Studio` /
                // `lms` CLI.
                return ["mlx[_-]vlm", "vllm", "LM Studio", "lms server"]
            }
        }
    }

    /// Raise the nice value (lower the scheduling priority) of every
    /// process matching one of `presets`' patterns by `delta`. Returns the
    /// list of adjustments for later restoration. Empty on failure or when
    /// nothing matched.
    @discardableResult
    public static func lower(presets: [ProviderPreset], by delta: Int = 10) -> [Entry] {
        let patterns = Array(Set(presets.flatMap(\.patterns)))
        let pids = findPids(matching: patterns)
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

    /// Undo a previous `lower(...)` call. Best-effort: a PID that has
    /// since exited (runner subprocess finished a request) is silently
    /// skipped.
    public static func restore(entries: [Entry]) {
        for entry in entries {
            _ = setpriority(entry.pid, to: entry.previousNice)
        }
    }

    // MARK: - Internals

    /// Return PIDs for every process whose command matches ANY of `patterns`.
    /// Each pattern is passed to `pgrep -f` (regex match on the full command
    /// line); results are unioned and deduped. Filters out our own PID
    /// defensively in case a pattern accidentally matches the app itself.
    private static func findPids(matching patterns: [String]) -> [Int32] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var seen = Set<Int32>()
        var out: [Int32] = []
        for pattern in patterns {
            let output = runCommand("/usr/bin/pgrep", args: ["-f", pattern]) ?? ""
            for line in output.split(whereSeparator: \.isNewline) {
                guard let pid = Int32(line), pid != ownPid, !seen.contains(pid) else { continue }
                seen.insert(pid)
                out.append(pid)
            }
        }
        return out
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

