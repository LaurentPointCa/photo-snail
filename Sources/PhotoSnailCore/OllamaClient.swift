import Foundation
import CoreGraphics

/// Image-handling options for the Ollama client. Defaults to downsizing to 1024 px long edge.
public struct OllamaImageOptions: Sendable {
    public var downsize: Bool
    public var maxPixelSize: Int
    public var jpegQuality: CGFloat

    public init(downsize: Bool = true, maxPixelSize: Int = 1024, jpegQuality: CGFloat = 0.8) {
        self.downsize = downsize
        self.maxPixelSize = maxPixelSize
        self.jpegQuality = jpegQuality
    }
}

/// Connection settings for reaching an Ollama instance.
///
/// Default targets the local Ollama daemon on the conventional port. Override
/// `baseURL` to point at a remote/proxied instance, set `apiKey` for proxies that
/// expect `Authorization: Bearer <key>`, or use `headers` for proxies with custom
/// auth schemes (e.g. `X-API-Key`, Basic auth). Headers override `apiKey` if both
/// set the `Authorization` field.
public struct OllamaConnection: Codable, Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var headers: [String: String]

    public init(baseURL: URL = URL(string: "http://localhost:11434")!,
                apiKey: String? = nil,
                headers: [String: String] = [:]) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.headers = headers
    }

    public static let `default` = OllamaConnection()

    /// Redacted form of `apiKey` for log lines: `sk-***` or `nil`.
    /// Always use this when printing the connection — never the raw key.
    public var redactedKey: String {
        guard let k = apiKey, !k.isEmpty else { return "(none)" }
        let prefix = k.prefix(3)
        return "\(prefix)***"
    }
}

/// One model entry returned by Ollama's `/api/tags` endpoint.
public struct OllamaModel: Codable, Sendable, Identifiable {
    public let name: String
    public let sizeBytes: Int64
    public let modifiedAt: String?

    public var id: String { name }

    public init(name: String, sizeBytes: Int64, modifiedAt: String?) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }

    /// Human-readable size like "9.6 GB" or "512 MB".
    public var sizeLabel: String {
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(sizeBytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }
}

/// Minimal HTTP client for the Ollama /api/generate endpoint with image attachments.
public final class OllamaClient {

    public let connection: OllamaConnection
    public let session: URLSession
    public var imageOptions: OllamaImageOptions

    public init(connection: OllamaConnection = .default,
                timeoutSeconds: TimeInterval = 1800,
                imageOptions: OllamaImageOptions = OllamaImageOptions()) {
        self.connection = connection
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        self.session = URLSession(configuration: config)
        self.imageOptions = imageOptions
    }

    /// Convenience for `baseURL` to keep call sites short.
    public var baseURL: URL { connection.baseURL }

    /// Send a prompt + image to Ollama and return the parsed CaptionResult.
    /// The image is downsized per `imageOptions` before being sent (default: 1024 px long edge, JPEG q=0.8).
    public func generateCaption(model: String, prompt: String, imagePath: String) async throws -> CaptionResult {
        let sourceData: Data
        let pixelW: Int
        let pixelH: Int
        if imageOptions.downsize {
            let result = try ImageDownsizer.downsizedJPEG(
                path: imagePath,
                maxPixelSize: imageOptions.maxPixelSize,
                quality: imageOptions.jpegQuality
            )
            sourceData = result.data
            pixelW = result.pixelWidth
            pixelH = result.pixelHeight
        } else {
            guard let raw = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
                throw PhotoSnailError.imageLoadFailed(imagePath)
            }
            sourceData = raw
            if let (_, _, w, h) = VisionAnalyzer.loadCGImageWithOrientation(imagePath) {
                pixelW = w
                pixelH = h
            } else {
                pixelW = 0
                pixelH = 0
            }
        }
        return try await sendToOllama(model: model, prompt: prompt, imageData: sourceData, pixelW: pixelW, pixelH: pixelH)
    }

    /// Send a prompt + in-memory image data to Ollama.
    /// `sourcePixelWidth`/`sourcePixelHeight` are the original dimensions before downsize (for reporting).
    public func generateCaption(model: String, prompt: String, imageData: Data,
                                sourcePixelWidth: Int, sourcePixelHeight: Int) async throws -> CaptionResult {
        let sendData: Data
        let pixelW: Int
        let pixelH: Int
        if imageOptions.downsize {
            let result = try ImageDownsizer.downsizedJPEG(
                data: imageData,
                maxPixelSize: imageOptions.maxPixelSize,
                quality: imageOptions.jpegQuality
            )
            sendData = result.data
            pixelW = result.pixelWidth
            pixelH = result.pixelHeight
        } else {
            sendData = imageData
            pixelW = sourcePixelWidth
            pixelH = sourcePixelHeight
        }
        return try await sendToOllama(model: model, prompt: prompt, imageData: sendData, pixelW: pixelW, pixelH: pixelH)
    }

    // MARK: - Shared Ollama HTTP call

    /// Apply the connection's auth + custom headers to a request.
    /// Bearer token is set first; explicit `headers` then override (so users
    /// can supply `Authorization: Basic ...` or any other scheme via `headers`).
    private func applyAuth(to req: inout URLRequest) {
        if let key = connection.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in connection.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
    }

    /// Fetch the list of locally-installed models from `/api/tags`.
    /// Used by the model picker in the CLI/GUI and the `--ollama-test` flag.
    public func listModels() async throws -> [OllamaModel] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        applyAuth(to: &req)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw PhotoSnailError.ollamaRequestFailed("listModels: \(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw PhotoSnailError.ollamaRequestFailed("listModels HTTP \(http.statusCode): \(body)")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhotoSnailError.ollamaResponseParseFailed("listModels: not a JSON object")
        }
        guard let models = obj["models"] as? [[String: Any]] else {
            throw PhotoSnailError.ollamaResponseParseFailed("listModels: missing 'models' array")
        }

        return models.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let size = (entry["size"] as? Int64) ?? Int64((entry["size"] as? Int) ?? 0)
            let modified = entry["modified_at"] as? String
            return OllamaModel(name: name, sizeBytes: size, modifiedAt: modified)
        }
    }

    // MARK: - Startup preflight

    /// Outcome of `preflight(model:)`. Each case carries the fix message
    /// the UI / CLI should surface so the user can copy-paste a resolution
    /// without switching contexts.
    public enum PreflightResult: Sendable, Equatable {
        /// Ollama is reachable and the configured model is installed.
        case ok
        /// Couldn't reach the baseURL at all (daemon not running, wrong URL,
        /// network error). Payload is a short one-line reason.
        case unreachable(reason: String)
        /// Connected, but the configured model isn't in `/api/tags`. Payload
        /// is the list of installed model names for a helpful error.
        case modelMissing(installed: [String])

        /// Short label for logging.
        public var shortLabel: String {
            switch self {
            case .ok: return "ok"
            case .unreachable: return "unreachable"
            case .modelMissing: return "model-missing"
            }
        }
    }

    /// Verify that (a) the Ollama daemon is reachable via the current
    /// connection and (b) the configured `model` tag is present locally.
    /// Runs at app startup so failures surface once, loud, with the exact
    /// commands needed to fix things — rather than mid-batch when the first
    /// generate call explodes.
    public func preflight(model: String) async -> PreflightResult {
        let models: [OllamaModel]
        do {
            models = try await listModels()
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
        let names = models.map { $0.name }
        if names.contains(model) {
            return .ok
        }
        return .modelMissing(installed: names)
    }

    // MARK: - Text-only generation (no image)

    /// Result from a text-only Ollama generation (translation, summarization, etc.).
    public struct TextResult: Sendable {
        public let model: String
        public let response: String
        public let elapsedSeconds: Double
    }

    /// Send a text-only prompt to Ollama (no image). Used for translation of
    /// existing descriptions where the input is text, not an image.
    public func generateText(model: String, prompt: String) async throws -> TextResult {
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "think": false,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &req)
        req.httpBody = payload

        let t0 = Date()
        let (data, response) = try await session.data(for: req)
        let elapsed = Date().timeIntervalSince(t0)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let respBody = String(data: data, encoding: .utf8) ?? "<binary>"
            throw PhotoSnailError.ollamaRequestFailed("HTTP \(http.statusCode): \(respBody)")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhotoSnailError.ollamaResponseParseFailed("not a JSON object")
        }
        guard let raw = obj["response"] as? String else {
            throw PhotoSnailError.ollamaResponseParseFailed("missing 'response' field")
        }

        return TextResult(model: model, response: raw, elapsedSeconds: elapsed)
    }

    // MARK: - Shared image Ollama HTTP call

    private func sendToOllama(model: String, prompt: String, imageData: Data,
                              pixelW: Int, pixelH: Int) async throws -> CaptionResult {
        let b64 = imageData.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "images": [b64],
            "stream": false,
            "think": false,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &req)
        req.httpBody = payload

        let t0 = Date()
        let (data, response) = try await session.data(for: req)
        let elapsed = Date().timeIntervalSince(t0)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw PhotoSnailError.ollamaRequestFailed("HTTP \(http.statusCode): \(body)")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhotoSnailError.ollamaResponseParseFailed("not a JSON object")
        }
        guard let raw = obj["response"] as? String else {
            throw PhotoSnailError.ollamaResponseParseFailed("missing 'response' field")
        }

        let parsed = CaptionParser.parse(raw)

        let promptTokens = obj["prompt_eval_count"] as? Int
        let promptEvalNs = (obj["prompt_eval_duration"] as? Int).map { Double($0) / 1e9 }
        let evalTokens = obj["eval_count"] as? Int
        let evalNs = (obj["eval_duration"] as? Int).map { Double($0) / 1e9 }
        let loadNs = (obj["load_duration"] as? Int).map { Double($0) / 1e9 }

        return CaptionResult(
            model: model,
            description: parsed.description,
            tags: parsed.tags,
            rawResponse: raw,
            elapsedSeconds: elapsed,
            promptEvalTokens: promptTokens,
            promptEvalSeconds: promptEvalNs,
            evalTokens: evalTokens,
            evalSeconds: evalNs,
            loadSeconds: loadNs,
            imageBytesSent: imageData.count,
            imagePixelWidth: pixelW,
            imagePixelHeight: pixelH
        )
    }
}
