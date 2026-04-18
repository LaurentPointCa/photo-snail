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
        var settings: Settings = .default
        var promptStyle: PromptStyle = .sideChannel
        var noDownsize: Bool = false
        var dbPath: URL = AssetQueue.defaultDBPath
        var concurrency: Int = 1
        var dryRun: Bool = false
        var limit: Int = 0  // 0 = unlimited

        var model: String { settings.model }
        var sentinel: String { settings.sentinel }
    }

    static func run(config: Config) async {
        // 0. Provider preflight — fail loud before any PhotoKit auth prompts
        //    or library enumeration, since the whole run depends on the LLM
        //    backend being reachable with the configured model.
        let imageOpts = OllamaImageOptions(downsize: !config.noDownsize)
        let preflightClient = config.settings.makeLLMClient(imageOptions: imageOpts)
        let providerName = config.settings.apiProvider.displayName
        let providerURL: String
        switch config.settings.apiProvider {
        case .ollama: providerURL = config.settings.ollama.baseURL.absoluteString
        case .openaiCompatible: providerURL = config.settings.openai.baseURL.absoluteString
        }
        let preflight = await preflightClient.preflight(model: config.model)
        switch preflight {
        case .ok:
            eprint("\(providerName) preflight: ok (\(config.model) @ \(providerURL))")
        case .unreachable(let reason):
            switch config.settings.apiProvider {
            case .ollama:
                eprint("""
                    ERROR: Ollama is not reachable at \(providerURL)
                    reason: \(reason)

                    Fix:
                      brew install ollama     # if not installed
                      ollama serve            # start the daemon
                      ollama pull \(config.model)    # pull the model

                    Or use --ollama-url to point at a different Ollama instance.
                    """)
            case .openaiCompatible:
                eprint("""
                    ERROR: OpenAI-compatible endpoint not reachable at \(providerURL)
                    reason: \(reason)

                    Start your local server (mlx-vlm, LM Studio, vLLM, ...) and
                    confirm `curl \(providerURL)/models` returns JSON. Or pass
                    --provider ollama to use Ollama instead.
                    """)
            }
            exit(2)
        case .modelMissing(let installed):
            let installedList = installed.isEmpty ? "  (none available)" : installed.map { "  \($0)" }.joined(separator: "\n")
            switch config.settings.apiProvider {
            case .ollama:
                eprint("""
                    ERROR: Ollama is reachable but model "\(config.model)" is not installed.

                    Installed models:
                    \(installedList)

                    Fix:
                      ollama pull \(config.model)

                    Or pass --model <name> to use a different model.
                    """)
            case .openaiCompatible:
                eprint("""
                    ERROR: OpenAI-compatible endpoint is reachable but model \
                    "\(config.model)" is not in /v1/models.

                    Available models:
                    \(installedList)

                    Load a different model on the server, or pass --model <name>.
                    """)
            }
            exit(2)
        }

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
        let settings = config.settings
        let sentinel = config.sentinel
        let dryRun = config.dryRun
        let limit = config.limit
        let concurrency = max(1, config.concurrency)
        let maxAttempts = 3
        let backoff: [TimeInterval] = [10, 30, 60]

        let doneCounter = DoneCounter(start: alreadyDone, total: total)

        // Dry-run uses an in-memory cursor over a snapshot of pending IDs so the
        // queue is never mutated. See CLAUDE.md "dry-run" for the rationale.
        let dryRunCursor: DryRunCursor?
        if dryRun {
            do {
                let snapshot = try await queue.peekAllPendingIds()
                dryRunCursor = DryRunCursor(ids: snapshot)
                eprint("dry-run: snapshot of \(snapshot.count) pending IDs taken — queue will not be mutated")
            } catch {
                eprint("ERROR snapshotting pending IDs: \(error)")
                exit(1)
            }
        } else {
            dryRunCursor = nil
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    let workerPipeline = Pipeline(
                        model: model,
                        promptStyle: promptStyle,
                        llm: settings.makeLLMClient(imageOptions: imageOpts)
                    )

                    while true {
                        // Source the next ID: dry-run uses the in-memory cursor (no
                        // queue mutation), real run uses claimNext (atomic claim).
                        let id: String
                        let attempts: Int
                        if let cursor = dryRunCursor {
                            guard let nextId = await cursor.next() else { return }
                            id = nextId
                            attempts = 1   // attempts has no meaning in dry-run
                        } else {
                            let claim: AssetQueue.Claim?
                            do {
                                claim = try await queue.claimNext()
                            } catch {
                                eprint("ERROR claimNext: \(error)")
                                return
                            }
                            guard let c = claim else { return }
                            id = c.id
                            attempts = c.attempts
                        }

                        do {
                            // Fetch image data from Photos
                            guard let asset = PhotoLibrary.fetch(id: id) else {
                                let err = PhotoSnailError.imageLoadFailed("PHAsset not found: \(id)")
                                if dryRun {
                                    eprint("[skipped \(String(id.prefix(8)))] asset not found")
                                } else {
                                    try? await queue.markFailed(id, error: err)
                                    eprint("[failed] asset not found: \(id)")
                                }
                                continue
                            }

                            let (imageData, _) = try await PhotoLibrary.requestImageData(for: asset)

                            // Run pipeline
                            let result = try await workerPipeline.process(imageData: imageData, identifier: id)

                            // Write back to Photos.app (unless dry-run)
                            if !dryRun {
                                let uuid = PhotoLibrary.uuidPrefix(id)
                                let preDesc = try await MainActor.run {
                                    try PhotosScripter.readDescription(uuid: uuid)
                                }
                                let payload = Pipeline.formatDescription(
                                    description: result.caption.description,
                                    tags: result.mergedTags,
                                    sentinel: sentinel,
                                    existingDescription: preDesc
                                )
                                let batchResult = try await MainActor.run {
                                    try PhotosScripter.runBatch(uuid: uuid, descriptionPayload: payload)
                                }
                                // Verify write landed
                                if !batchResult.postDescription.contains(sentinel) {
                                    eprint("[warn] sentinel not found in post-write description for \(id)")
                                }
                            }

                            // Only mark done AFTER write-back succeeds — and only in real mode.
                            // Dry-run intentionally leaves the queue untouched.
                            if !dryRun {
                                try? await queue.markDone(id, result: result, sentinel: sentinel)
                            }
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
                            if dryRun {
                                eprint("[skipped \(String(id.prefix(8)))] \(e.shortMessage)")
                                // No markFailed, no retry — just move on.
                            } else if e.isRetriable && attempts < maxAttempts {
                                try? await queue.recordRetry(id, error: e)
                                let delay = backoff[attempts - 1]
                                eprint("[retry \(attempts)/\(maxAttempts)] \(id) — \(e.shortMessage), sleeping \(Int(delay))s")
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            } else {
                                try? await queue.markFailed(id, error: e)
                                eprint("[failed] \(id) — \(e.shortMessage)")
                            }
                        } catch let e as ScripterError {
                            // ScripterError can only happen in non-dry-run path because
                            // the AppleScript call is gated on `!dryRun` above.
                            let wrapped = PhotoSnailError.ollamaRequestFailed("AppleScript: \(e)")
                            try? await queue.markFailed(id, error: wrapped)
                            eprint("[failed] \(id) — \(e)")
                        } catch {
                            if dryRun {
                                eprint("[skipped \(String(id.prefix(8)))] \(error)")
                            } else {
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
