import Foundation
import PhotoSnailCore
import PhotoSnailPhotos

/// GUI port of the `--scan-multi`, `--scan-preserved`, and `--clean-multi`
/// diagnostics in `photo-snail-app`. Kept as free async functions so each
/// tool window gets its own run without singleton coordination — a window
/// holds a `Task`, passes closures for progress + incremental findings,
/// and cancels the Task to stop.
///
/// The actual scan shape matches the CLI versions (same Pipeline +
/// Sentinel helpers, same separator constant, same AppleScript path via
/// `PhotosScripter.readDescription`). If you're auditing this against the
/// CLI implementations in `PhotoSnailApp/App.swift`, the two paths
/// deliberately mirror each other — any logic change should land in both.
enum ToolsEngine {

    // MARK: - Shared types

    /// One match from `scanMulti`. Numbers match the CLI's output columns:
    /// sentinel count, separator count, total description length, plus a
    /// preview truncated to keep the results list readable.
    struct MultiFinding: Identifiable, Hashable, Sendable {
        let id: String              // PHAsset.localIdentifier
        let sentinels: Int
        let separators: Int
        let length: Int
        let preview: String         // one-line, ⏎-substituted, truncated
    }

    /// One match from `scanPreserved`. `userPrefix` is the raw text before
    /// the sentinel-bearing segment; the UI renders it in full because the
    /// whole point is to read what the user wrote.
    struct PreservedFinding: Identifiable, Hashable, Sendable {
        let id: String
        let userPrefix: String
        let descriptionLength: Int
    }

    /// One candidate from the clean-multi scan. `before` and `after` carry
    /// the full descriptions so the UI can show a diff and the writer has
    /// everything it needs without re-reading.
    struct CleanCandidate: Identifiable, Hashable, Sendable {
        let id: String
        let before: String
        let after: String
        var byteDelta: Int { before.count - after.count }
    }

    /// Progress tick passed to the UI during a scan. The view only needs
    /// scanned/total/foundCount/errors to render the header; incremental
    /// findings arrive via a separate callback.
    struct Progress: Sendable {
        let scanned: Int
        let total: Int
        let found: Int
        let errors: Int
    }

    // MARK: - Queue opening

    /// Open the shared queue at the default path. Two AssetQueue instances
    /// across the app (main engine + this one) are safe: the queue runs
    /// SQLite in WAL mode so concurrent readers don't block each other,
    /// and tools only read (except the clean writes via PhotosScripter,
    /// which doesn't touch the queue at all).
    static func openQueue() async throws -> AssetQueue {
        try AssetQueue(dbPath: AssetQueue.defaultDBPath)
    }

    /// Collect every `done` asset id across every sentinel family. Matches
    /// the CLI path — uses `distinctSentinels` + `idsWithSentinel` so a
    /// library with mixed sentinel families (post-model-swap) still gets
    /// every row scanned.
    static func fetchDoneIds(queue: AssetQueue) async throws -> [String] {
        let sentinels = try await queue.distinctSentinels()
        var all: [String] = []
        for s in sentinels {
            all.append(contentsOf: try await queue.idsWithSentinel(s))
        }
        return Array(Set(all))
    }

    // MARK: - Scan: multi-segment descriptions

    /// Iterate every done asset; report descriptions with >=2 sentinels
    /// or >=2 separators (same criterion as the `--scan-multi` CLI).
    /// Findings are delivered incrementally via `onFinding` so the results
    /// list can stream — each AppleScript call is ~50-100ms and users
    /// shouldn't have to wait for the whole scan to see matches.
    @MainActor
    static func scanMulti(
        ids: [String],
        onProgress: (Progress) -> Void,
        onFinding: (MultiFinding) -> Void
    ) async {
        let separator = "\n\n---\n\n"
        let re = try! NSRegularExpression(pattern: Sentinel.sentinelPattern, options: [])
        var scanned = 0
        var errors = 0
        var found = 0

        for id in ids {
            if Task.isCancelled { return }
            let uuid = PhotoLibrary.uuidPrefix(id)
            let desc: String
            do {
                desc = try PhotosScripter.readDescription(uuid: uuid)
            } catch {
                errors += 1
                scanned += 1
                if scanned % 25 == 0 || scanned == ids.count {
                    onProgress(Progress(scanned: scanned, total: ids.count, found: found, errors: errors))
                }
                continue
            }
            let range = NSRange(desc.startIndex..., in: desc)
            let sentinels = re.numberOfMatches(in: desc, options: [], range: range)
            let separators = desc.components(separatedBy: separator).count - 1
            if sentinels >= 2 || separators >= 2 {
                let preview = makePreview(desc, maxLength: 100)
                onFinding(MultiFinding(
                    id: id,
                    sentinels: sentinels,
                    separators: separators,
                    length: desc.count,
                    preview: preview
                ))
                found += 1
            }
            scanned += 1
            if scanned % 25 == 0 || scanned == ids.count {
                onProgress(Progress(scanned: scanned, total: ids.count, found: found, errors: errors))
            }
        }
    }

    // MARK: - Scan: preserved original descriptions

    /// Iterate every done asset; report assets where the user authored
    /// their own text BEFORE our payload, which we then preserved across
    /// the `\n\n---\n\n` separator. Uses `Pipeline.splitExistingDescription`
    /// — the same splitter the write-back uses — so "user prefix" means
    /// exactly what it means during write time.
    @MainActor
    static func scanPreserved(
        ids: [String],
        onProgress: (Progress) -> Void,
        onFinding: (PreservedFinding) -> Void
    ) async {
        var scanned = 0
        var errors = 0
        var found = 0

        for id in ids {
            if Task.isCancelled { return }
            let uuid = PhotoLibrary.uuidPrefix(id)
            let desc: String
            do {
                desc = try PhotosScripter.readDescription(uuid: uuid)
            } catch {
                errors += 1
                scanned += 1
                if scanned % 25 == 0 || scanned == ids.count {
                    onProgress(Progress(scanned: scanned, total: ids.count, found: found, errors: errors))
                }
                continue
            }
            let (userPrefix, hasPayload) = Pipeline.splitExistingDescription(desc)
            let trimmed = userPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if hasPayload && !trimmed.isEmpty {
                onFinding(PreservedFinding(
                    id: id,
                    userPrefix: trimmed,
                    descriptionLength: desc.count
                ))
                found += 1
            }
            scanned += 1
            if scanned % 25 == 0 || scanned == ids.count {
                onProgress(Progress(scanned: scanned, total: ids.count, found: found, errors: errors))
            }
        }
    }

    // MARK: - Clean: collapse multi-segment descriptions

    /// Dry-run phase of `--clean-multi`: scans every done asset, collects
    /// collapse candidates via `Pipeline.collapseMultiSegment`. Writing is
    /// a separate step (`applyCleanCandidates`) so the UI can surface the
    /// dry-run diff before the user flips the Apply toggle.
    @MainActor
    static func scanCleanCandidates(
        ids: [String],
        onProgress: (Progress) -> Void,
        onFinding: (CleanCandidate) -> Void
    ) async {
        var scanned = 0
        var errors = 0
        var found = 0

        for id in ids {
            if Task.isCancelled { return }
            let uuid = PhotoLibrary.uuidPrefix(id)
            let current: String
            do {
                current = try PhotosScripter.readDescription(uuid: uuid)
            } catch {
                errors += 1
                scanned += 1
                if scanned % 25 == 0 || scanned == ids.count {
                    onProgress(Progress(scanned: scanned, total: ids.count, found: found, errors: errors))
                }
                continue
            }
            if let cleaned = Pipeline.collapseMultiSegment(current), cleaned != current {
                onFinding(CleanCandidate(id: id, before: current, after: cleaned))
                found += 1
            }
            scanned += 1
            if scanned % 25 == 0 || scanned == ids.count {
                onProgress(Progress(scanned: scanned, total: ids.count, found: found, errors: errors))
            }
        }
    }

    /// Write each cleaned description back via `PhotosScripter.runBatch`
    /// — the same read-write-verify AppleScript block the worker uses.
    /// Errors per asset are collected and reported; one failure doesn't
    /// halt the rest. `collapseMultiSegment` is idempotent so re-running
    /// a partial failure is safe.
    @MainActor
    static func applyCleanCandidates(
        _ candidates: [CleanCandidate],
        onResult: (_ id: String, _ success: Bool, _ error: String?) -> Void
    ) async {
        for c in candidates {
            if Task.isCancelled { return }
            let uuid = PhotoLibrary.uuidPrefix(c.id)
            do {
                let res = try PhotosScripter.runBatch(uuid: uuid, descriptionPayload: c.after)
                if res.postDescription == c.after {
                    onResult(c.id, true, nil)
                } else {
                    onResult(c.id, false, "post-description mismatch")
                }
            } catch {
                onResult(c.id, false, String(describing: error))
            }
        }
    }

    // MARK: - Helpers

    /// Compact a description for one-line display in a results table.
    /// Strips newlines (replaced with ⏎ glyph), trims to `maxLength` with
    /// an ellipsis if longer. Same style as the CLI's stdout preview.
    private static func makePreview(_ text: String, maxLength: Int) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: "⏎")
        if oneLine.count > maxLength {
            return String(oneLine.prefix(maxLength)) + "…"
        }
        return oneLine
    }
}
