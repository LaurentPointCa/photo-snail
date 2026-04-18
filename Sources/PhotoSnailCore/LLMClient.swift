import Foundation

/// Which LLM backend to talk to. Persisted in `Settings.apiProvider`.
/// The default is `ollama` to preserve the project's privacy-first default
/// (a local daemon that never phones home). `openaiCompatible` is intended
/// for **locally-hosted** OpenAI-compatible endpoints like mlx-vlm, LM
/// Studio's local server, vLLM, etc. — NOT for api.openai.com.
public enum LLMProvider: String, Codable, Sendable, CaseIterable {
    case ollama
    case openaiCompatible = "openai-compatible"

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .openaiCompatible: return "OpenAI-compatible (local)"
        }
    }
}

/// One model entry returned by a provider's model-listing endpoint. Unified
/// across Ollama (`/api/tags`, size known) and OpenAI-compatible
/// (`/v1/models`, size unknown — `sizeBytes` is nil).
public struct LLMModel: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let sizeBytes: Int64?
    public let modifiedAt: String?

    public var id: String { name }

    public init(name: String, sizeBytes: Int64? = nil, modifiedAt: String? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }

    /// Human-readable size like "9.6 GB" or "512 MB", or nil if unknown.
    public var sizeLabel: String? {
        guard let sizeBytes else { return nil }
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(sizeBytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }
}

/// Backwards-compatible alias used throughout the codebase from Phase A–L.
public typealias OllamaModel = LLMModel

/// Outcome of an LLM preflight check. Same shape across providers so the
/// UI sheet can present a single "unreachable / model missing / ok" branch.
public enum LLMPreflightResult: Sendable, Equatable {
    case ok
    case unreachable(reason: String)
    case modelMissing(installed: [String])

    public var shortLabel: String {
        switch self {
        case .ok: return "ok"
        case .unreachable: return "unreachable"
        case .modelMissing: return "model-missing"
        }
    }
}

/// Text-only generation result (used for translation).
public struct LLMTextResult: Sendable {
    public let model: String
    public let response: String
    public let elapsedSeconds: Double

    public init(model: String, response: String, elapsedSeconds: Double) {
        self.model = model
        self.response = response
        self.elapsedSeconds = elapsedSeconds
    }
}

/// Abstraction over the two supported LLM backends. `Pipeline` takes `any
/// LLMClient` so the same orchestration runs against either provider.
public protocol LLMClient: Sendable {
    var providerLabel: String { get }
    func listModels() async throws -> [LLMModel]
    func preflight(model: String) async -> LLMPreflightResult
    func generateCaption(model: String,
                         prompt: String,
                         imageData: Data,
                         sourcePixelWidth: Int,
                         sourcePixelHeight: Int) async throws -> CaptionResult
    func generateText(model: String, prompt: String) async throws -> LLMTextResult
}
