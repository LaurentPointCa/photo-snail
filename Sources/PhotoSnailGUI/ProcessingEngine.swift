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

    /// Called on the MainActor when `currentPhotoID` changes so the store
    /// can mirror the value without optional-chaining through `engine?`.
    var onCurrentPhotoChanged: ((String?) -> Void)? = nil

    // Current photo being processed (bottom half)
    var currentPhotoID: String? = nil {
        didSet { onCurrentPhotoChanged?(currentPhotoID) }
    }
    var currentThumbnail: CGImage? = nil

    // Last completed photo (top half)
    var completedPhotoID: String? = nil
    var completedThumbnail: CGImage? = nil
    var completedDescription: String = ""
    var completedTags: [String] = []

    var photosProcessedThisSession: Int = 0
    var sessionStartTime: Date? = nil
    var photosPerHour: Double = 0
    var etaString: String = "--"

    var failures: [FailedAsset] = []
    var statusMessage: String = ""

    struct FailedAsset: Identifiable {
        let id: String
        let error: String
        let attempts: Int
    }

    private let log = LogStore.shared

    // MARK: - Config (driven by Settings on disk)

    var model: String = Settings.default.model
    var sentinel: String = Settings.default.sentinel
    var connection: OllamaConnection = .default
    var customPrompt: String? = nil
    var promptLanguage: String? = nil
    var dryRun: Bool = false

    /// Models discovered from Ollama at startup. Empty until `refreshAvailableModels()`
    /// completes (or returns empty if Ollama is unreachable).
    var availableModels: [OllamaModel] = []
    var modelsLoadError: String? = nil

    // MARK: - Private

    /// Shared with `LibraryStore` — both observe the same actor instance
    /// so worker mutations fan out to the store's row cache via the
    /// change stream. The store owns the queue's lifetime; we just hold
    /// a reference to it for our own reads/writes.
    /// Exposed read-only for the settings sheet's requeue dialog.
    let queue: AssetQueue
    private var workerTask: Task<Void, Never>?
    private var isPausedFlag = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Init

    init(queue: AssetQueue) {
        self.queue = queue
    }

    // MARK: - Initial load (no processing, just stats + settings + Ollama probe)

    func loadInitialStats() async {
        self.statusMessage = Localizer.shared.t("status.ready")

        // 1. Load settings from disk (or defaults). Apply env-var overrides for runtime.
        let loaded: Settings
        do {
            loaded = try Settings.load()
        } catch {
            statusMessage = "\(Localizer.shared.t("error.settings_error")): \(error)"
            return
        }
        let runtime = loaded.withEnvOverrides()
        self.model = runtime.model
        self.sentinel = runtime.sentinel
        self.connection = runtime.ollama
        self.customPrompt = runtime.customPrompt
        self.promptLanguage = runtime.promptLanguage

        // 2. Queue stats. The queue was passed in at init — we just read.
        do {
            try await refreshStats()
        } catch {
            statusMessage = "\(Localizer.shared.t("error.queue_open_failed")): \(error)"
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
    func applyConfigChange(model: String, sentinel: String, connection: OllamaConnection,
                           customPrompt: String? = nil, promptLanguage: String? = nil) async {
        self.model = model
        self.sentinel = sentinel
        self.connection = connection
        self.customPrompt = customPrompt
        self.promptLanguage = promptLanguage

        // Persist (without env-var overrides — those are runtime-only).
        // Build a Settings from current state, but strip the env-var key if present
        // so we don't accidentally write the env value to disk.
        let envKey = ProcessInfo.processInfo.environment["PHOTO_SNAIL_OLLAMA_API_KEY"]
        var persisted = connection
        if let envKey = envKey, !envKey.isEmpty, persisted.apiKey == envKey {
            persisted.apiKey = nil
        }
        let s = Settings(model: model, sentinel: sentinel, ollama: persisted,
                         customPrompt: customPrompt, promptLanguage: promptLanguage)
        do {
            try s.save()
            statusMessage = Localizer.shared.t("status.settings_saved")
        } catch {
            statusMessage = "\(Localizer.shared.t("error.save_failed")): \(error)"
        }

        // Re-probe Ollama with the new connection.
        await refreshAvailableModels()
    }

    // MARK: - Controls

    func start() async {
        guard state == .idle || state == .finished else { return }
        state = .enumerating
        statusMessage = Localizer.shared.t("status.requesting_photos")
        log.append(.info, "Requesting Photos access")

        let authStatus = await PhotoLibrary.requestAuth()
        guard authStatus == .authorized else {
            statusMessage = "\(Localizer.shared.t("error.photos_access_denied")) (\(PhotoLibrary.authStatusLabel(authStatus)))"
            log.append(.error, "Photos access denied: \(PhotoLibrary.authStatusLabel(authStatus))")
            state = .idle
            return
        }

        do {
            statusMessage = Localizer.shared.t("status.enumerating")
            log.append(.info, "Enumerating library...")
            _ = try await PhotoLibraryEnumerator.fetchUnprocessedIdentifiers(
                queue: queue,
                sentinel: sentinel,
                log: { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
            )

            try await refreshStats()

            if pendingCount == 0 {
                statusMessage = Localizer.shared.t("status.all_processed")
                log.append(.success, "All photos already processed")
                state = .finished
                return
            }

            state = .running
            sessionStartTime = Date()
            photosProcessedThisSession = 0
            statusMessage = "\(Localizer.shared.t("status.processing_verb"))..."
            log.append(.info, "Processing started — \(pendingCount) pending, \(doneCount) done, \(failedCount) failed")

            launchWorker()
        } catch {
            statusMessage = "\(Localizer.shared.t("label.error")): \(error)"
            log.append(.error, "Start failed: \(error)")
            state = .idle
        }
    }

    func pause() {
        isPausedFlag = true
        statusMessage = Localizer.shared.t("status.pausing")
        log.append(.info, "Pause requested")
    }

    func resume() {
        isPausedFlag = false
        state = .running
        statusMessage = Localizer.shared.t("status.resuming")
        log.append(.info, "Resumed")
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func retryFailed(_ id: String) async {
        do {
            try await queue.requeueFailed(id)
            try await refreshStats()
            try await refreshFailures()
            statusMessage = "\(Localizer.shared.t("button.reprocess")) \(String(id.prefix(8)))..."
        } catch {
            statusMessage = "\(Localizer.shared.t("error.retry_error")): \(error)"
        }
    }

    func retryAllFailed() async {
        for failure in failures {
            try? await queue.requeueFailed(failure.id)
        }
        try? await refreshStats()
        try? await refreshFailures()
        statusMessage = String(format: Localizer.shared.t("status.requeued_failed"), failures.count)
    }

    // MARK: - Worker

    private func launchWorker() {
        // Capture the queue (and other settings) into locals so the detached
        // worker task can reference them without a main-actor hop. All are
        // Sendable: `AssetQueue` is an actor, the rest are value types.
        let queue = self.queue
        let model = self.model
        let sentinel = self.sentinel
        let connection = self.connection
        let customPrompt = self.customPrompt
        let promptLanguage = self.promptLanguage
        let dryRun = self.dryRun

        // Capture localized strings before detaching — launchWorker() is on
        // MainActor so Localizer.shared is accessible here.
        let loc = Localizer.shared
        let verbProcessing = loc.t("status.processing_verb")
        let verbTranslating = loc.t("status.translating_verb")
        let locPaused = loc.t("status.paused")
        let locDryrunComplete = loc.t("status.dryrun_complete")
        let locQueueError = loc.t("error.queue_open_failed")
        let locAllProcessed = loc.t("status.all_processed")
        let locAssetNotFound = loc.t("error.asset_not_found")

        // Dry-run uses an in-memory cursor over a snapshot of pending IDs so the
        // queue is never mutated. Build it on the actor before detaching the worker.
        let dryRunCursorTask: Task<DryRunCursor?, Error> = Task {
            guard dryRun else { return nil }
            let snapshot = try await queue.peekAllPendingIds()
            return DryRunCursor(ids: snapshot)
        }

        workerTask = Task.detached { [weak self] in
            let ollamaClient = OllamaClient(connection: connection)
            let pipeline = Pipeline(
                model: model,
                promptStyle: .sideChannel,
                ollama: ollamaClient,
                customPrompt: customPrompt
            )

            let dryRunCursor: DryRunCursor?
            let log = await LogStore.shared
            do {
                dryRunCursor = try await dryRunCursorTask.value
                if dryRunCursor != nil {
                    await MainActor.run { log.append(.info, "Dry-run: snapshot taken") }
                }
            } catch {
                await MainActor.run {
                    self?.statusMessage = "Snapshot error: \(error)"
                    log.append(.error, "Snapshot error: \(error)")
                }
                return
            }

            while true {
                // Pause check
                if await self?.isPausedFlag == true {
                    await MainActor.run {
                        self?.state = .paused
                        self?.statusMessage = locPaused
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
                let taskType: String
                if let cursor = dryRunCursor {
                    guard let nextId = await cursor.next() else {
                        await MainActor.run {
                            self?.state = .finished
                            self?.statusMessage = locDryrunComplete
                            log.append(.success, "Dry-run complete — queue not mutated")
                        }
                        return
                    }
                    id = nextId
                    attempts = 1
                    taskType = "caption"
                } else {
                    let claim: AssetQueue.Claim?
                    do {
                        claim = try await queue.claimNext()
                    } catch {
                        await MainActor.run {
                            self?.statusMessage = "\(locQueueError): \(error)"
                            log.append(.error, "Queue error: \(error)")
                        }
                        return
                    }
                    guard let c = claim else {
                        await MainActor.run {
                            self?.state = .finished
                            self?.statusMessage = locAllProcessed
                            log.append(.success, "All photos processed")
                        }
                        return
                    }
                    id = c.id
                    attempts = c.attempts
                    taskType = c.taskType
                }

                await MainActor.run {
                    self?.currentPhotoID = id
                    let verb = taskType == "translate" ? verbTranslating : verbProcessing
                    self?.statusMessage = "\(verb) \(String(id.prefix(8)))..."
                    log.append(.info, "\(verb) \(String(id.prefix(8)))…", assetId: id)
                }

                // Load thumbnail for preview
                if let asset = PhotoLibrary.fetch(id: id) {
                    let thumb = await Self.loadThumbnail(asset: asset)
                    await MainActor.run { self?.currentThumbnail = thumb }
                }

                // Translation branch: text-only Ollama call, no image/Vision
                if taskType == "translate" && !dryRun {
                    do {
                        let row = try await queue.fetchRow(id: id)
                        guard let origDesc = row?.originalDescription, !origDesc.isEmpty else {
                            let err = PhotoSnailError.imageLoadFailed("No original description to translate: \(id)")
                            try? await queue.markFailed(id, error: err)
                            await self?.refreshStatsAndFailures()
                            continue
                        }
                        let origTags = row?.originalTags.isEmpty == false ? row!.originalTags : row?.tags ?? []
                        let langName = Localizer.languageName(for: promptLanguage ?? "en")
                        let translationPrompt = """
                            Translate the following photo description and tags to \(langName). \
                            Keep the same format exactly. Do not add or remove content, just translate.
                            DESCRIPTION: <translated description>
                            TAGS: <translated tag1>, <translated tag2>, ...

                            Original:
                            DESCRIPTION: \(origDesc)
                            TAGS: \(origTags.joined(separator: ", "))
                            """
                        let t0 = Date()
                        let textResult = try await ollamaClient.generateText(model: model, prompt: translationPrompt)
                        let ollamaMs = Int64(Date().timeIntervalSince(t0) * 1000)
                        let parsed = CaptionParser.parse(textResult.response)

                        let payload = Pipeline.formatDescription(
                            description: parsed.description,
                            tags: parsed.tags,
                            sentinel: sentinel
                        )
                        let uuid = PhotoLibrary.uuidPrefix(id)
                        _ = try await MainActor.run {
                            try PhotosScripter.runBatch(uuid: uuid, descriptionPayload: payload)
                        }

                        try? await queue.markTranslationDone(
                            id, description: parsed.description, tags: parsed.tags,
                            sentinel: sentinel, model: model, ollamaMs: ollamaMs
                        )

                        await MainActor.run {
                            self?.completedPhotoID = self?.currentPhotoID
                            self?.completedThumbnail = self?.currentThumbnail
                            self?.completedDescription = parsed.description
                            self?.completedTags = parsed.tags
                            self?.currentThumbnail = nil
                            self?.photosProcessedThisSession += 1
                            self?.updateThroughput()
                            log.append(.success, "Translated: \(String(id.prefix(8)))", assetId: id)
                        }
                        await self?.refreshStatsAndFailures()
                    } catch let e as PhotoSnailError {
                        if e.isRetriable && attempts < 3 {
                            try? await queue.recordRetry(id, error: e)
                            try? await Task.sleep(nanoseconds: UInt64([10, 30, 60][attempts - 1]) * 1_000_000_000)
                        } else {
                            try? await queue.markFailed(id, error: e)
                        }
                        await self?.refreshStatsAndFailures()
                    } catch {
                        let wrapped = PhotoSnailError.ollamaRequestFailed("\(error)")
                        try? await queue.markFailed(id, error: wrapped)
                        await self?.refreshStatsAndFailures()
                    }
                    continue
                }

                // Caption process (standard image pipeline)
                do {
                    guard let asset = PhotoLibrary.fetch(id: id) else {
                        let err = PhotoSnailError.imageLoadFailed("PHAsset not found: \(id)")
                        if !dryRun {
                            try? await queue.markFailed(id, error: err)
                        }
                        await MainActor.run {
                            self?.statusMessage = "\(locAssetNotFound): \(String(id.prefix(8)))"
                            log.append(.error, "Asset not found: \(String(id.prefix(8)))", assetId: id)
                        }
                        await self?.refreshStatsAndFailures()
                        continue
                    }

                    let (imageData, _) = try await PhotoLibrary.requestImageData(for: asset)
                    let result = try await pipeline.process(imageData: imageData, identifier: id)
                    let elapsed = String(format: "%.1f", result.totalElapsedSeconds)
                    await MainActor.run {
                        log.append(.info, "Pipeline complete for \(String(id.prefix(8))) (\(elapsed)s)", assetId: id)
                    }

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
                        await MainActor.run {
                            log.append(.info, "Write-back complete for \(String(id.prefix(8)))", assetId: id)
                        }
                    }

                    // markDone only in real mode — dry-run leaves the queue untouched.
                    if !dryRun {
                        try? await queue.markDone(id, result: result, sentinel: sentinel)
                    }

                    await MainActor.run {
                        self?.completedPhotoID = self?.currentPhotoID
                        self?.completedThumbnail = self?.currentThumbnail
                        self?.completedDescription = result.caption.description
                        self?.completedTags = result.mergedTags
                        self?.currentThumbnail = nil
                        self?.photosProcessedThisSession += 1
                        self?.updateThroughput()
                        log.append(.success, "Done: \(String(id.prefix(8))) — \(result.mergedTags.count) tags", assetId: id)
                    }
                    if !dryRun {
                        await self?.refreshStatsAndFailures()
                    }

                } catch let e as PhotoSnailError {
                    if dryRun {
                        await MainActor.run {
                            self?.statusMessage = "Skipped \(String(id.prefix(8))): \(e.shortMessage)"
                            log.append(.warning, "Dry-run skipped \(String(id.prefix(8))): \(e.shortMessage)", assetId: id)
                        }
                    } else if e.isRetriable && attempts < 3 {
                        try? await queue.recordRetry(id, error: e)
                        await MainActor.run {
                            self?.statusMessage = "Retrying \(String(id.prefix(8)))..."
                            log.append(.warning, "Retrying \(String(id.prefix(8))) (attempt \(attempts)): \(e.shortMessage)", assetId: id)
                        }
                        try? await Task.sleep(nanoseconds: UInt64([10, 30, 60][attempts - 1]) * 1_000_000_000)
                        await self?.refreshStatsAndFailures()
                    } else {
                        try? await queue.markFailed(id, error: e)
                        await MainActor.run {
                            log.append(.error, "Failed: \(String(id.prefix(8))) — \(e.shortMessage)", assetId: id)
                        }
                        await self?.refreshStatsAndFailures()
                    }
                } catch {
                    if dryRun {
                        await MainActor.run {
                            self?.statusMessage = "Skipped \(String(id.prefix(8))): \(error)"
                            log.append(.warning, "Dry-run skipped \(String(id.prefix(8))): \(error)", assetId: id)
                        }
                    } else {
                        let wrapped = PhotoSnailError.ollamaRequestFailed("\(error)")
                        try? await queue.markFailed(id, error: wrapped)
                        await MainActor.run {
                            log.append(.error, "Failed: \(String(id.prefix(8))) — \(error)", assetId: id)
                        }
                        await self?.refreshStatsAndFailures()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshStats() async throws {
        let stats = try await queue.stats()
        totalCount = stats.total
        doneCount = stats.done
        pendingCount = stats.pending
        failedCount = stats.failed
    }

    private func refreshFailures() async throws {
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
