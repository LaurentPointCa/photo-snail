import Foundation
import Photos
import PhotoSnailCore
import CoreGraphics

@Observable
@MainActor
final class ProcessingEngine {

    enum State { case idle, enumerating, running, paused, finished }

    // MARK: - Published state

    var state: State = .idle

    var totalCount: Int = 0
    var doneCount: Int = 0
    var pendingCount: Int = 0
    var failedCount: Int = 0

    // Current photo being processed (bottom half)
    var currentPhotoID: String? = nil
    var currentThumbnail: CGImage? = nil

    // Last completed photo (top half)
    var completedThumbnail: CGImage? = nil
    var completedDescription: String = ""
    var completedTags: [String] = []

    var photosProcessedThisSession: Int = 0
    var sessionStartTime: Date? = nil
    var photosPerHour: Double = 0
    var etaString: String = "--"

    var failures: [FailedAsset] = []
    var statusMessage: String = "Ready"

    struct FailedAsset: Identifiable {
        let id: String
        let error: String
        let attempts: Int
    }

    // MARK: - Config (driven by Settings on disk)

    var model: String = Settings.default.model
    var sentinel: String = Settings.default.sentinel
    var connection: OllamaConnection = .default
    var dryRun: Bool = false

    /// Models discovered from Ollama at startup. Empty until `refreshAvailableModels()`
    /// completes (or returns empty if Ollama is unreachable).
    var availableModels: [OllamaModel] = []
    var modelsLoadError: String? = nil

    // MARK: - Private

    private var queue: AssetQueue?
    private var workerTask: Task<Void, Never>?
    private var isPausedFlag = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Initial load (no processing, just stats + settings + Ollama probe)

    func loadInitialStats() async {
        // 1. Load settings from disk (or defaults). Apply env-var overrides for runtime.
        let loaded: Settings
        do {
            loaded = try Settings.load()
        } catch {
            statusMessage = "Settings error: \(error)"
            return
        }
        let runtime = loaded.withEnvOverrides()
        self.model = runtime.model
        self.sentinel = runtime.sentinel
        self.connection = runtime.ollama

        // 2. Open the queue.
        do {
            let q = try AssetQueue(dbPath: AssetQueue.defaultDBPath)
            self.queue = q
            try await refreshStats()
        } catch {
            statusMessage = "Queue error: \(error)"
        }

        // 3. Kick off Ollama model discovery in the background — non-blocking.
        Task { await refreshAvailableModels() }
    }

    /// Probe Ollama and update `availableModels`. Safe to call repeatedly
    /// (e.g. after the user changes the connection in the settings sheet).
    func refreshAvailableModels() async {
        let conn = self.connection
        let client = OllamaClient(connection: conn)
        do {
            let models = try await client.listModels()
            await MainActor.run {
                self.availableModels = models.sorted { $0.name < $1.name }
                self.modelsLoadError = nil
            }
        } catch {
            await MainActor.run {
                self.availableModels = []
                self.modelsLoadError = "\(error)"
            }
        }
    }

    /// Apply a model + sentinel + connection change from the settings sheet.
    /// Persists to settings.json. Caller is responsible for asking the user
    /// about sentinel choice on a family change BEFORE calling this.
    /// Changes take effect on the next `start()` — does NOT interrupt a running batch.
    func applyConfigChange(model: String, sentinel: String, connection: OllamaConnection) async {
        self.model = model
        self.sentinel = sentinel
        self.connection = connection

        // Persist (without env-var overrides — those are runtime-only).
        // Build a Settings from current state, but strip the env-var key if present
        // so we don't accidentally write the env value to disk.
        let envKey = ProcessInfo.processInfo.environment["PHOTO_SNAIL_OLLAMA_API_KEY"]
        var persisted = connection
        if let envKey = envKey, !envKey.isEmpty, persisted.apiKey == envKey {
            persisted.apiKey = nil
        }
        let s = Settings(model: model, sentinel: sentinel, ollama: persisted)
        do {
            try s.save()
            statusMessage = "Settings saved"
        } catch {
            statusMessage = "Save failed: \(error)"
        }

        // Re-probe Ollama with the new connection.
        await refreshAvailableModels()
    }

    // MARK: - Controls

    func start() async {
        guard state == .idle || state == .finished else { return }
        state = .enumerating
        statusMessage = "Requesting Photos access..."

        let authStatus = await PhotoLibrary.requestAuth()
        guard authStatus == .authorized else {
            statusMessage = "Photos access denied (\(PhotoLibrary.authStatusLabel(authStatus)))"
            state = .idle
            return
        }

        do {
            if queue == nil {
                queue = try AssetQueue(dbPath: AssetQueue.defaultDBPath)
            }
            guard let queue = queue else { return }

            statusMessage = "Enumerating library..."
            _ = try await PhotoLibraryEnumerator.fetchUnprocessedIdentifiers(
                queue: queue,
                sentinel: sentinel,
                log: { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
            )

            try await refreshStats()

            if pendingCount == 0 {
                statusMessage = "All photos processed"
                state = .finished
                return
            }

            state = .running
            sessionStartTime = Date()
            photosProcessedThisSession = 0
            statusMessage = "Processing..."

            launchWorker()
        } catch {
            statusMessage = "Error: \(error)"
            state = .idle
        }
    }

    func pause() {
        isPausedFlag = true
        statusMessage = "Pausing after current photo..."
    }

    func resume() {
        isPausedFlag = false
        state = .running
        statusMessage = "Resuming..."
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func retryFailed(_ id: String) async {
        guard let queue = queue else { return }
        do {
            try await queue.requeueFailed(id)
            try await refreshStats()
            try await refreshFailures()
            statusMessage = "Re-queued \(String(id.prefix(8)))..."
        } catch {
            statusMessage = "Retry error: \(error)"
        }
    }

    func retryAllFailed() async {
        guard let queue = queue else { return }
        for failure in failures {
            try? await queue.requeueFailed(failure.id)
        }
        try? await refreshStats()
        try? await refreshFailures()
        statusMessage = "Re-queued \(failures.count) failed assets"
    }

    // MARK: - Worker

    private func launchWorker() {
        guard let queue = queue else { return }
        let model = self.model
        let sentinel = self.sentinel
        let connection = self.connection
        let dryRun = self.dryRun

        // Dry-run uses an in-memory cursor over a snapshot of pending IDs so the
        // queue is never mutated. Build it on the actor before detaching the worker.
        let dryRunCursorTask: Task<DryRunCursor?, Error> = Task {
            guard dryRun else { return nil }
            let snapshot = try await queue.peekAllPendingIds()
            return DryRunCursor(ids: snapshot)
        }

        workerTask = Task.detached { [weak self] in
            let pipeline = Pipeline(
                model: model,
                promptStyle: .sideChannel,
                ollama: OllamaClient(connection: connection)
            )

            let dryRunCursor: DryRunCursor?
            do {
                dryRunCursor = try await dryRunCursorTask.value
            } catch {
                await MainActor.run { self?.statusMessage = "Snapshot error: \(error)" }
                return
            }

            while true {
                // Pause check
                if await self?.isPausedFlag == true {
                    await MainActor.run {
                        self?.state = .paused
                        self?.statusMessage = "Paused"
                    }
                    await withCheckedContinuation { cont in
                        Task { @MainActor in
                            self?.pauseContinuation = cont
                        }
                    }
                }

                // Source the next ID: dry-run uses the in-memory cursor (no
                // queue mutation), real run uses claimNext.
                let id: String
                let attempts: Int
                if let cursor = dryRunCursor {
                    guard let nextId = await cursor.next() else {
                        await MainActor.run {
                            self?.state = .finished
                            self?.statusMessage = "Dry-run complete (queue not mutated)"
                        }
                        return
                    }
                    id = nextId
                    attempts = 1
                } else {
                    let claim: AssetQueue.Claim?
                    do {
                        claim = try await queue.claimNext()
                    } catch {
                        await MainActor.run { self?.statusMessage = "Queue error: \(error)" }
                        return
                    }
                    guard let c = claim else {
                        await MainActor.run {
                            self?.state = .finished
                            self?.statusMessage = "All photos processed"
                        }
                        return
                    }
                    id = c.id
                    attempts = c.attempts
                }

                await MainActor.run {
                    self?.currentPhotoID = id
                    self?.statusMessage = "Processing \(String(id.prefix(8)))..."
                }

                // Load thumbnail for preview
                if let asset = PhotoLibrary.fetch(id: id) {
                    let thumb = await Self.loadThumbnail(asset: asset)
                    await MainActor.run { self?.currentThumbnail = thumb }
                }

                // Process
                do {
                    guard let asset = PhotoLibrary.fetch(id: id) else {
                        let err = PhotoSnailError.imageLoadFailed("PHAsset not found: \(id)")
                        if !dryRun {
                            try? await queue.markFailed(id, error: err)
                        }
                        await MainActor.run { self?.statusMessage = "Asset not found: \(String(id.prefix(8)))" }
                        await self?.refreshStatsAndFailures()
                        continue
                    }

                    let (imageData, _) = try await PhotoLibrary.requestImageData(for: asset)
                    let result = try await pipeline.process(imageData: imageData, identifier: id)

                    if !dryRun {
                        let payload = Pipeline.formatDescription(
                            description: result.caption.description,
                            tags: result.mergedTags,
                            sentinel: sentinel
                        )
                        let uuid = PhotoLibrary.uuidPrefix(id)
                        _ = try await MainActor.run {
                            try PhotosScripter.runBatch(uuid: uuid, descriptionPayload: payload)
                        }
                    }

                    // markDone only in real mode — dry-run leaves the queue untouched.
                    if !dryRun {
                        try? await queue.markDone(id, result: result, sentinel: sentinel)
                    }

                    await MainActor.run {
                        // Promote current → completed
                        self?.completedThumbnail = self?.currentThumbnail
                        self?.completedDescription = result.caption.description
                        self?.completedTags = result.mergedTags
                        self?.currentThumbnail = nil
                        self?.photosProcessedThisSession += 1
                        self?.updateThroughput()
                    }
                    if !dryRun {
                        await self?.refreshStatsAndFailures()
                    }

                } catch let e as PhotoSnailError {
                    if dryRun {
                        await MainActor.run { self?.statusMessage = "Skipped \(String(id.prefix(8))): \(e.shortMessage)" }
                    } else if e.isRetriable && attempts < 3 {
                        try? await queue.recordRetry(id, error: e)
                        await MainActor.run { self?.statusMessage = "Retrying \(String(id.prefix(8)))..." }
                        try? await Task.sleep(nanoseconds: UInt64([10, 30, 60][attempts - 1]) * 1_000_000_000)
                        await self?.refreshStatsAndFailures()
                    } else {
                        try? await queue.markFailed(id, error: e)
                        await self?.refreshStatsAndFailures()
                    }
                } catch {
                    if dryRun {
                        await MainActor.run { self?.statusMessage = "Skipped \(String(id.prefix(8))): \(error)" }
                    } else {
                        let wrapped = PhotoSnailError.ollamaRequestFailed("\(error)")
                        try? await queue.markFailed(id, error: wrapped)
                        await self?.refreshStatsAndFailures()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshStats() async throws {
        guard let queue = queue else { return }
        let stats = try await queue.stats()
        totalCount = stats.total
        doneCount = stats.done
        pendingCount = stats.pending
        failedCount = stats.failed
    }

    private func refreshFailures() async throws {
        guard let queue = queue else { return }
        let rows = try await queue.listFailed()
        failures = rows.map { FailedAsset(id: $0.id, error: $0.error, attempts: $0.attempts) }
    }

    private nonisolated func refreshStatsAndFailures() async {
        Task { @MainActor in
            try? await self.refreshStats()
            try? await self.refreshFailures()
        }
    }

    private func updateThroughput() {
        guard let start = sessionStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 && photosProcessedThisSession > 0 else { return }
        photosPerHour = Double(photosProcessedThisSession) / (elapsed / 3600)
        let remaining = pendingCount
        if photosPerHour > 0 {
            let secondsLeft = Double(remaining) / photosPerHour * 3600
            etaString = Self.formatDuration(secondsLeft)
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private static func loadThumbnail(asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                guard let data = data,
                      let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 400,
                      ] as CFDictionary) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: thumb)
            }
        }
    }
}
