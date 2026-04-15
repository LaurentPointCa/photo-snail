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

    /// When true, `handleScreenLocked` auto-starts the worker if the queue
    /// has work and `handleScreenUnlocked` pauses it afterwards. Persisted
    /// in Settings.autoStartWhenLocked; loaded in `loadInitialStats`.
    var autoStartWhenLocked: Bool = false

    /// Tracks whether the current run was initiated by the lock watcher so
    /// we only auto-pause on unlock if we auto-started on lock (don't
    /// pause a user-initiated batch just because they unlocked).
    private var startedByLockWatcher: Bool = false

    /// Models discovered from Ollama at startup. Empty until `refreshAvailableModels()`
    /// completes (or returns empty if Ollama is unreachable).
    var availableModels: [OllamaModel] = []
    var modelsLoadError: String? = nil

    /// Startup Ollama preflight status. The UI surfaces a blocking sheet when
    /// this is `.failed(...)`. `.dismissed` means the user chose "Continue
    /// anyway" and further failures should NOT re-present the sheet this
    /// session (the user has acknowledged). A successful retry flips back to
    /// `.ok`.
    enum PreflightStatus: Sendable, Equatable {
        case checking
        case ok
        case failed(OllamaClient.PreflightResult)
        case dismissed
    }
    var preflightStatus: PreflightStatus = .checking

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

    /// Exposed for the UI: true from the moment the user hits Pause until
    /// the worker actually reaches its next pause checkpoint. Lets the
    /// RunnerDock swap the Pause button for a disabled "Waiting to
    /// finish…" label so double-clicks don't do anything weird.
    var isPausing: Bool { isPausedFlag && state == .running }

    /// "Process now" target. When the worker finishes processing an asset
    /// whose id matches this, it flips `isPausedFlag` so the next loop
    /// iteration parks in the pause continuation. Cleared as part of the
    /// pause so subsequent Resume / Start runs aren't also one-shot.
    private var stopAfterPhotoID: String? = nil

    /// Lives for the engine's lifetime. Instantiated in `loadInitialStats`
    /// (after settings are loaded) and forwards screen lock/unlock events
    /// to `handleScreenLocked` / `handleScreenUnlocked`.
    private var lockWatcher: LockWatcher?

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
        self.autoStartWhenLocked = runtime.autoStartWhenLocked

        // 2. Queue stats. The queue was passed in at init — we just read.
        do {
            try await refreshStats()
        } catch {
            statusMessage = "\(Localizer.shared.t("error.queue_open_failed")): \(error)"
        }

        // 3. Kick off Ollama model discovery in the background — non-blocking.
        Task { await refreshAvailableModels() }

        // 4. Run the startup Ollama preflight. Non-blocking from this
        //    method's perspective (so the library view renders immediately),
        //    but the UI surfaces a modal sheet as soon as the result comes
        //    back if it's a failure.
        Task { await self.runPreflight() }

        // 5. Install the lock watcher. Callbacks check autoStartWhenLocked
        //    themselves so flipping the toggle takes effect on the next
        //    lock event without re-wiring observers.
        if self.lockWatcher == nil {
            self.lockWatcher = LockWatcher(
                onLock: { [weak self] in
                    Task { @MainActor in await self?.handleScreenLocked() }
                },
                onUnlock: { [weak self] in
                    Task { @MainActor in self?.handleScreenUnlocked() }
                }
            )
        }
    }

    /// Re-run the Ollama preflight. Invoked at startup and when the user
    /// clicks "Retry" in the preflight failure sheet. Clears `.dismissed`
    /// if the retry succeeds so a subsequent failure can surface again.
    func runPreflight() async {
        await MainActor.run { self.preflightStatus = .checking }
        let client = OllamaClient(connection: self.connection)
        let result = await client.preflight(model: self.model)
        await MainActor.run {
            switch result {
            case .ok:
                self.preflightStatus = .ok
                self.log.append(.info, "Ollama preflight: ok (\(self.model))")
            case .unreachable, .modelMissing:
                // If the user already dismissed this session, don't pester.
                if case .dismissed = self.preflightStatus {
                    self.log.append(.warning, "Ollama preflight failed (dismissed): \(result)")
                } else {
                    self.preflightStatus = .failed(result)
                    self.log.append(.error, "Ollama preflight failed: \(result.shortLabel)")
                }
            }
        }
    }

    /// "Continue anyway" from the preflight sheet: acknowledge the failure
    /// and stop surfacing the sheet until next app launch.
    func dismissPreflight() {
        self.preflightStatus = .dismissed
        self.log.append(.warning, "Ollama preflight dismissed by user")
    }

    // MARK: - Lock-triggered auto-start

    /// Called by LockWatcher when the Mac locks. If the auto-start toggle
    /// is on AND the queue has pending work AND we're currently idle,
    /// start the worker and remember we did so (so unlock pauses it).
    func handleScreenLocked() async {
        guard autoStartWhenLocked else { return }
        guard state == .idle || state == .finished else { return }
        try? await refreshStats()
        guard pendingCount > 0 else {
            log.append(.info, "Screen locked — no pending work, staying idle")
            return
        }
        log.append(.info, "Screen locked — auto-starting queue (\(pendingCount) pending)")
        startedByLockWatcher = true
        await start()
    }

    /// Called by LockWatcher when the Mac unlocks. Pauses the worker only
    /// if the current run was lock-initiated; leaves user-initiated runs
    /// alone so unlock doesn't interrupt work the user explicitly started.
    func handleScreenUnlocked() {
        guard autoStartWhenLocked else { return }
        guard startedByLockWatcher else {
            log.append(.info, "Screen unlocked — run was user-initiated, leaving alone")
            return
        }
        startedByLockWatcher = false
        guard state == .running else { return }
        log.append(.info, "Screen unlocked — auto-pausing queue")
        pause()
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
                         customPrompt: customPrompt, promptLanguage: promptLanguage,
                         autoStartWhenLocked: autoStartWhenLocked)
        do {
            try s.save()
            statusMessage = Localizer.shared.t("status.settings_saved")
        } catch {
            statusMessage = "\(Localizer.shared.t("error.save_failed")): \(error)"
        }

        // Re-probe Ollama with the new connection.
        await refreshAvailableModels()
    }

    /// Toggle the auto-start-when-locked preference and persist to disk.
    /// The LockWatcher polls this property; no need to re-wire observers.
    func setAutoStartWhenLocked(_ flag: Bool) {
        self.autoStartWhenLocked = flag
        // Load, update, and re-save settings so we don't stomp on unrelated fields.
        do {
            var s = try Settings.load()
            s.autoStartWhenLocked = flag
            try s.save()
            log.append(.info, "autoStartWhenLocked = \(flag)")
        } catch {
            log.append(.error, "Failed to persist autoStartWhenLocked: \(error)")
        }
    }

    // MARK: - Controls

    /// Start processing whatever's currently pending in the queue. Does NOT
    /// enumerate the library — that's now the "Add to Queue" action's job.
    /// If the queue is empty, the engine stays idle and surfaces a hint.
    func start() async {
        guard state == .idle || state == .finished else { return }
        try? await refreshStats()

        if pendingCount == 0 {
            statusMessage = Localizer.shared.t("status.queue_empty_hint")
            log.append(.info, "Start ignored — queue is empty")
            state = .idle
            return
        }

        state = .running
        sessionStartTime = Date()
        photosProcessedThisSession = 0
        statusMessage = "\(Localizer.shared.t("status.processing_verb"))..."
        log.append(.info, "Processing started — \(pendingCount) pending, \(doneCount) done, \(failedCount) failed")

        launchWorker()
    }

    /// Enumerate the user's Photos library and enqueue every asset that
    /// isn't already processed (sentinel bootstrap marks matching assets as
    /// done without re-running the pipeline). First call on a fresh install
    /// builds the initial queue; subsequent calls pick up newly-added photos.
    func addAllUnprocessedToQueue() async {
        guard state == .idle || state == .finished else { return }
        state = .enumerating
        statusMessage = Localizer.shared.t("status.requesting_photos")
        log.append(.info, "Requesting Photos access (Add all unprocessed)")

        let authStatus = await PhotoLibrary.requestAuth()
        guard authStatus == .authorized else {
            statusMessage = "\(Localizer.shared.t("error.photos_access_denied")) (\(PhotoLibrary.authStatusLabel(authStatus)))"
            log.append(.error, "Photos access denied: \(PhotoLibrary.authStatusLabel(authStatus))")
            state = .idle
            return
        }

        do {
            statusMessage = Localizer.shared.t("status.loading_from_photos")
            log.append(.info, "Enumerating library...")
            _ = try await PhotoLibraryEnumerator.fetchUnprocessedIdentifiers(
                queue: queue,
                sentinel: sentinel,
                log: { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
            )

            try await refreshStats()
            state = .idle
            statusMessage = String(format: Localizer.shared.t("status.added_to_queue"), pendingCount)
            log.append(.success, "Enumeration done — \(pendingCount) pending, \(doneCount) done")
        } catch {
            statusMessage = "\(Localizer.shared.t("label.error")): \(error)"
            log.append(.error, "Add-all-unprocessed failed: \(error)")
            state = .idle
        }
    }

    /// Upsert-enqueue a specific set of local identifiers. Existing rows are
    /// reset to pending (so reprocessing a `done` photo works without the
    /// old Re-Process action); new ids get a fresh pending row. No
    /// enumeration, no Photos auth check — the caller already has rows for
    /// these ids in the library view.
    func addSelectedToQueue(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await queue.addOrRequeue(ids)
            try await refreshStats()
            statusMessage = String(format: Localizer.shared.t("status.added_to_queue"), ids.count)
            log.append(.info, "Added \(ids.count) photo(s) to queue (selected)")
        } catch {
            statusMessage = "\(Localizer.shared.t("label.error")): \(error)"
            log.append(.error, "Add-selected failed: \(error)")
        }
    }

    /// "Process now" on a single asset: bumps it to priority=1 so it's the
    /// very next row claimNext picks, arms the stop-after-this-photo flag
    /// so the worker pauses right after finishing, and (if idle) starts
    /// the worker. Net effect: user clicks Process now → exactly one
    /// photo is processed → queue returns to paused/finished. No drain
    /// of the rest of the queue.
    ///
    /// No-op if the asset is currently in-flight (the worker already owns
    /// it — the stop flag would fire on its natural completion anyway,
    /// but we don't want to pretend we scheduled anything new).
    func processNow(id: String) async {
        do {
            let wasReset = try await queue.processNow(id: id)
            try await refreshStats()
            if !wasReset {
                statusMessage = Localizer.shared.t("status.already_processing")
                log.append(.info, "Process now: \(String(id.prefix(8))) is already in-flight")
                return
            }
            stopAfterPhotoID = id
            log.append(.info, "Process now: \(String(id.prefix(8))) queued at priority=1; worker will pause after")
            if state == .idle || state == .finished {
                await start()
            }
        } catch {
            statusMessage = "\(Localizer.shared.t("label.error")): \(error)"
            log.append(.error, "Process-now failed: \(error)")
        }
    }

    /// Called by the worker (on MainActor) after a successful markDone
    /// so Process now's one-shot semantics can trigger a pause without
    /// the worker having direct access to `isPausedFlag`. Returns true
    /// if we just triggered a stop so the caller can update state.
    @discardableResult
    fileprivate func consumeStopAfterIfMatches(_ id: String) -> Bool {
        guard stopAfterPhotoID == id else { return false }
        stopAfterPhotoID = nil
        isPausedFlag = true
        statusMessage = Localizer.shared.t("status.pausing")
        log.append(.info, "Process now done — pausing worker")
        return true
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
        // Try to lower Ollama's scheduling priority so interactive apps
        // stay responsive during long batches. Silent on failure — this
        // is a nice-to-have, not a correctness requirement. The worker's
        // `defer` below restores the original nice values on exit (normal
        // finish, cancellation, or errors) so other tools sharing Ollama
        // don't keep feeling the lowered priority forever.
        let priorityEntries = OllamaPriorityManager.lower(by: 10)
        if !priorityEntries.isEmpty {
            let pids = priorityEntries.map { "\($0.pid)(\($0.previousNice)→\($0.newNice))" }.joined(separator: ", ")
            log.append(.info, "Lowered Ollama priority: \(pids)")
        }

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
            // Restore Ollama's nice values on ANY exit path — normal
            // completion, cancellation, unexpected throw. Kept out of the
            // MainActor so the restore still runs if the engine is torn
            // down mid-batch.
            defer {
                OllamaPriorityManager.restore(entries: priorityEntries)
            }

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

                        let uuid = PhotoLibrary.uuidPrefix(id)
                        let preDesc = try await MainActor.run {
                            try PhotosScripter.readDescription(uuid: uuid)
                        }
                        let payload = Pipeline.formatDescription(
                            description: parsed.description,
                            tags: parsed.tags,
                            sentinel: sentinel,
                            existingDescription: preDesc
                        )
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

                    // "Process now" one-shot: if this photo was the
                    // explicit Process-now target, arm the pause flag so
                    // the next loop iteration parks instead of draining
                    // the rest of the queue.
                    await MainActor.run {
                        self?.consumeStopAfterIfMatches(id)
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
