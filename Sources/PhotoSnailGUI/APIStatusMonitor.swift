import Foundation
import PhotoSnailCore

/// Live observability layer for the LLM provider. Powers the bottom status
/// bar: a connection pill (Connected / Unreachable / Unknown) plus a single
/// "tail" slot describing the most recent request going out or response
/// coming back. LogStore is still the authoritative scrollback; this is the
/// pulse for "is something happening right now?" during 60 s/photo waits.
///
/// Populated from two sides:
/// 1. `MonitoredLLMClient` wraps every `LLMClient` call and emits
///    `begin`/`end` around `generateCaption`, `generateText`, `listModels`.
/// 2. `ProcessingEngine.runPreflight` calls `noteHandshake` after the
///    provider preflight so the pill reflects the baseline state before
///    the first real request runs.
@Observable
@MainActor
final class APIStatusMonitor {
    static let shared = APIStatusMonitor()

    // MARK: - Types

    enum ConnectionState: Equatable {
        case unknown
        case connected(providerLabel: String)
        case failed(reason: String)

        var isHealthy: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    enum EventPhase: Equatable {
        case inFlight(startedAt: Date)
        case completed(duration: TimeInterval)
        case failed(duration: TimeInterval, reason: String)
    }

    struct APIEvent: Identifiable, Equatable {
        let id: UInt64
        let call: String
        let model: String?
        let assetId: String?
        let startedAt: Date
        var phase: EventPhase
        /// When false, ending this event won't touch `connectionState`.
        /// Write-back (Photos.app AppleScript) uses this so a successful
        /// write doesn't overwrite the LLM pill with its own health.
        var tracksConnection: Bool = true
    }

    // MARK: - Observed state

    private(set) var connectionState: ConnectionState = .unknown
    private(set) var lastEvent: APIEvent?
    private(set) var providerLabel: String = ""

    /// Current photo asset ID (the one the worker is processing). Set by
    /// `ProcessingEngine` as `currentPhotoID` changes; picked up by
    /// `begin()` so each event gets stamped with the photo it belongs to.
    private(set) var currentAssetId: String?

    // MARK: - Private

    private var nextId: UInt64 = 0

    private init() {}

    /// Bridge for ProcessingEngine: updates the "current photo" context
    /// so subsequent begin() calls attribute their events to this asset.
    /// Clearing (nil) is fine between photos.
    func setCurrentAsset(id: String?) {
        self.currentAssetId = id
    }

    // MARK: - Call-site hooks (used by MonitoredLLMClient)

    /// Record a new in-flight request. Returns a token the caller passes
    /// back to `end(token:success:reason:)`. The new event becomes the
    /// current `lastEvent` regardless of what was there before — overlapping
    /// requests just mean the tail shows whichever begin fired most recently.
    func begin(
        call: String,
        model: String?,
        assetId: String? = nil,
        providerLabel: String,
        tracksConnection: Bool = true
    ) -> UInt64 {
        let id = nextId
        nextId &+= 1
        // Only remember the providerLabel for events that actually represent
        // the LLM provider — otherwise "writeBack" would hijack the pill.
        if tracksConnection {
            self.providerLabel = providerLabel
        }
        let now = Date()
        // Fall back to the engine-supplied `currentAssetId` so per-photo
        // calls get tagged even though the LLMClient protocol can't carry
        // the asset id through its signature.
        let resolvedAsset = assetId ?? currentAssetId
        self.lastEvent = APIEvent(
            id: id,
            call: call,
            model: model,
            assetId: resolvedAsset,
            startedAt: now,
            phase: .inFlight(startedAt: now),
            tracksConnection: tracksConnection
        )
        return id
    }

    /// Finalize a request. Updates connection state on every call (so any
    /// failure flips the pill to Unreachable, and any subsequent success
    /// recovers it). Only overwrites `lastEvent` if the token still matches
    /// the current slot — otherwise a newer in-flight event is already
    /// holding the tail, and we let it.
    func end(token: UInt64, success: Bool, reason: String?) {
        let now = Date()

        // Phase bookkeeping — keep the tail showing the most recently-begun
        // event. If the token doesn't match, the slot has moved on.
        var tracksConnection = true
        if var event = lastEvent, event.id == token {
            let elapsed = now.timeIntervalSince(event.startedAt)
            event.phase = success
                ? .completed(duration: elapsed)
                : .failed(duration: elapsed, reason: reason ?? "error")
            self.lastEvent = event
            tracksConnection = event.tracksConnection
        }

        // Connection state — only events that represent the LLM provider
        // move the pill. Write-back (Photos.app) success shouldn't
        // overwrite the LLM pill, and a write-back failure shouldn't turn
        // the LLM pill red either.
        guard tracksConnection else { return }
        if success {
            self.connectionState = .connected(providerLabel: providerLabel)
        } else {
            self.connectionState = .failed(reason: reason ?? "error")
        }
    }

    // MARK: - Preflight bridge

    /// Called by `ProcessingEngine.runPreflight`. Sets the pill based on the
    /// richer `LLMPreflightResult` enum (unreachable vs model-missing vs ok).
    /// No `lastEvent` entry is written — the preflight call itself goes
    /// through `MonitoredLLMClient` and produces its own begin/end pair.
    func noteHandshake(_ result: LLMPreflightResult, providerLabel: String) {
        self.providerLabel = providerLabel
        switch result {
        case .ok:
            self.connectionState = .connected(providerLabel: providerLabel)
        case .unreachable(let reason):
            self.connectionState = .failed(reason: "unreachable: \(reason)")
        case .modelMissing(let installed):
            let hint = installed.isEmpty ? "no models installed" : "model not installed"
            self.connectionState = .failed(reason: hint)
        }
    }

    /// Reset to initial state. Used on provider switches so a stale
    /// "Connected to Ollama" pill doesn't linger while we're probing the
    /// new OpenAI-compatible endpoint.
    func reset(providerLabel: String) {
        self.providerLabel = providerLabel
        self.connectionState = .unknown
        self.lastEvent = nil
    }
}
