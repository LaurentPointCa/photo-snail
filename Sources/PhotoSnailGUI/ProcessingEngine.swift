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

    // MARK: - Config

    var model: String = "gemma4:31b"
    var sentinel: String = "ai:gemma4-v1"
    var dryRun: Bool = false

    // MARK: - Private

    private var queue: AssetQueue?
    private var workerTask: Task<Void, Never>?
    private var isPausedFlag = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Initial load (no processing, just stats)

    func loadInitialStats() async {
        do {
            let q = try AssetQueue(dbPath: AssetQueue.defaultDBPath)
            self.queue = q
            try await refreshStats()
        } catch {
            statusMessage = "Queue error: \(error)"
        }
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
        let dryRun = self.dryRun

        workerTask = Task.detached { [weak self] in
            let pipeline = Pipeline(
                model: model,
                promptStyle: .sideChannel,
                ollama: OllamaClient()
            )

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

                // Claim next
                let claim: AssetQueue.Claim?
                do {
                    claim = try await queue.claimNext()
                } catch {
                    await MainActor.run { self?.statusMessage = "Queue error: \(error)" }
                    return
                }
                guard let claim = claim else {
                    await MainActor.run {
                        self?.state = .finished
                        self?.statusMessage = "All photos processed"
                    }
                    return
                }

                let id = claim.id

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
                        try? await queue.markFailed(id, error: err)
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

                    try? await queue.markDone(id, result: result)

                    await MainActor.run {
                        // Promote current → completed
                        self?.completedThumbnail = self?.currentThumbnail
                        self?.completedDescription = result.caption.description
                        self?.completedTags = result.mergedTags
                        self?.currentThumbnail = nil
                        self?.photosProcessedThisSession += 1
                        self?.updateThroughput()
                    }
                    await self?.refreshStatsAndFailures()

                } catch let e as PhotoSnailError {
                    if e.isRetriable && claim.attempts < 3 {
                        try? await queue.recordRetry(id, error: e)
                        await MainActor.run { self?.statusMessage = "Retrying \(String(id.prefix(8)))..." }
                        try? await Task.sleep(nanoseconds: UInt64([10, 30, 60][claim.attempts - 1]) * 1_000_000_000)
                    } else {
                        try? await queue.markFailed(id, error: e)
                    }
                    await self?.refreshStatsAndFailures()
                } catch {
                    let wrapped = PhotoSnailError.ollamaRequestFailed("\(error)")
                    try? await queue.markFailed(id, error: wrapped)
                    await self?.refreshStatsAndFailures()
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
