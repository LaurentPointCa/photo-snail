import Foundation
import Photos
import PhotoSnailCore

/// Wires PhotoKit enumeration → AssetQueue → Pipeline → PhotosScripter write-back.
///
/// Critical ordering: `markDone` runs only AFTER `PhotosScripter.runBatch` succeeds,
/// so a crash between Pipeline and Scripter leaves the row `in_progress` for the
/// resume sweep on next startup.
enum QueueRunner {

    struct Config {
        var model: String = "gemma4:31b"
        var promptStyle: PromptStyle = .sideChannel
        var noDownsize: Bool = false
        var dbPath: URL = AssetQueue.defaultDBPath
        var concurrency: Int = 1
        var sentinel: String = "ai:gemma4-v1"
        var dryRun: Bool = false
        var limit: Int = 0  // 0 = unlimited
    }

    static func run(config: Config) async {
        // 1. PhotoKit auth
        let status = await PhotoLibrary.requestAuth()
        guard status == .authorized else {
            eprint("ERROR: Photo Library auth \(PhotoLibrary.authStatusLabel(status)). Grant Full Access in System Settings > Privacy & Security > Photos.")
            exit(1)
        }
        eprint("auth: \(PhotoLibrary.authStatusLabel(status))")

        // 2. Open queue
        let queue: AssetQueue
        do {
            queue = try AssetQueue(dbPath: config.dbPath)
        } catch {
            eprint("ERROR opening queue at \(config.dbPath.path): \(error)")
            exit(1)
        }

        // 3. Enumerate and enqueue unprocessed assets
        do {
            _ = try await PhotoLibraryEnumerator.fetchUnprocessedIdentifiers(
                queue: queue,
                sentinel: config.sentinel
            )
        } catch {
            eprint("ERROR enumerating library: \(error)")
            exit(1)
        }

        // 4. Show queue state
        let startStats: AssetQueue.Stats
        do {
            startStats = try await queue.stats()
        } catch {
            eprint("ERROR reading queue stats: \(error)")
            exit(1)
        }
        let total = startStats.total
        let alreadyDone = startStats.done
        eprint("starting: \(startStats.pending) to process, \(alreadyDone) already done, \(total) total")

        if startStats.pending == 0 {
            eprint("nothing to process — all assets are done or failed")
            return
        }

        // 5. Worker loop
        let model = config.model
        let promptStyle = config.promptStyle
        let imageOpts = OllamaImageOptions(downsize: !config.noDownsize)
        let sentinel = config.sentinel
        let dryRun = config.dryRun
        let limit = config.limit
        let concurrency = max(1, config.concurrency)
        let maxAttempts = 3
        let backoff: [TimeInterval] = [10, 30, 60]

        let doneCounter = DoneCounter(start: alreadyDone, total: total)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    let workerPipeline = Pipeline(
                        model: model,
                        promptStyle: promptStyle,
                        ollama: OllamaClient(imageOptions: imageOpts)
                    )

                    while true {
                        let claim: AssetQueue.Claim?
                        do {
                            claim = try await queue.claimNext()
                        } catch {
                            eprint("ERROR claimNext: \(error)")
                            return
                        }
                        guard let claim = claim else { return }
                        let id = claim.id
                        let attempts = claim.attempts

                        do {
                            // Fetch image data from Photos
                            guard let asset = PhotoLibrary.fetch(id: id) else {
                                let err = PhotoSnailError.imageLoadFailed("PHAsset not found: \(id)")
                                try? await queue.markFailed(id, error: err)
                                eprint("[failed] asset not found: \(id)")
                                continue
                            }

                            let (imageData, _) = try await PhotoLibrary.requestImageData(for: asset)

                            // Run pipeline
                            let result = try await workerPipeline.process(imageData: imageData, identifier: id)

                            // Write back to Photos.app (unless dry-run)
                            if !dryRun {
                                let payload = Pipeline.formatDescription(
                                    description: result.caption.description,
                                    tags: result.mergedTags,
                                    sentinel: sentinel
                                )
                                let uuid = PhotoLibrary.uuidPrefix(id)
                                let batchResult = try await MainActor.run {
                                    try PhotosScripter.runBatch(uuid: uuid, descriptionPayload: payload)
                                }
                                // Verify write landed
                                if !batchResult.postDescription.contains(sentinel) {
                                    eprint("[warn] sentinel not found in post-write description for \(id)")
                                }
                            }

                            // Only mark done AFTER write-back succeeds
                            try? await queue.markDone(id, result: result)
                            let count = await doneCounter.increment()
                            let secs = String(format: "%.1fs", result.totalElapsedSeconds)
                            let preview = String(result.caption.description.prefix(60))
                            let mode = dryRun ? " (dry-run)" : ""
                            print("[\(count)/\(total) a\(attempts)] \(secs) \(preview)\(mode)")
                            fflush(stdout)

                            // Limit check: stop after N new photos processed
                            if limit > 0 && (count - alreadyDone) >= limit {
                                return
                            }

                        } catch let e as PhotoSnailError {
                            if e.isRetriable && attempts < maxAttempts {
                                try? await queue.recordRetry(id, error: e)
                                let delay = backoff[attempts - 1]
                                eprint("[retry \(attempts)/\(maxAttempts)] \(id) — \(e.shortMessage), sleeping \(Int(delay))s")
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            } else {
                                try? await queue.markFailed(id, error: e)
                                eprint("[failed] \(id) — \(e.shortMessage)")
                            }
                        } catch let e as ScripterError {
                            // AppleScript failures are not retriable (permission/script bugs)
                            let wrapped = PhotoSnailError.ollamaRequestFailed("AppleScript: \(e)")
                            try? await queue.markFailed(id, error: wrapped)
                            eprint("[failed] \(id) — \(e)")
                        } catch {
                            let wrapped = PhotoSnailError.ollamaRequestFailed("\(error)")
                            if wrapped.isRetriable && attempts < maxAttempts {
                                try? await queue.recordRetry(id, error: wrapped)
                                let delay = backoff[attempts - 1]
                                eprint("[retry \(attempts)/\(maxAttempts)] \(id) — \(error), sleeping \(Int(delay))s")
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            } else {
                                try? await queue.markFailed(id, error: wrapped)
                                eprint("[failed] \(id) — \(error)")
                            }
                        }
                    }
                }
            }
        }

        if let finalStats = try? await queue.stats() {
            eprint("done: \(finalStats.done) done, \(finalStats.failed) failed, \(finalStats.pending) pending")
        }
    }
}

/// Thread-safe counter for tracking completed assets across concurrent workers.
private actor DoneCounter {
    private var count: Int
    private let total: Int

    init(start: Int, total: Int) {
        self.count = start
        self.total = total
    }

    func increment() -> Int {
        count += 1
        return count
    }
}

private func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
