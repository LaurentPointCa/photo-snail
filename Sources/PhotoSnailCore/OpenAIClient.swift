import Foundation
import CoreGraphics

/// Connection settings for an OpenAI-compatible HTTP endpoint.
///
/// **Intended for locally-hosted servers** — mlx-vlm, LM Studio, vLLM, etc.
/// The default `baseURL` targets the convention used by most local servers
/// (port 8080 on localhost). The user is expected to override it.
///
/// `apiKey` is sent as `Authorization: Bearer <key>`. Most local servers
/// don't require one — leave it nil. Headers override `apiKey` if both set
/// `Authorization`.
public struct OpenAIConnection: Codable, Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var headers: [String: String]

    public init(baseURL: URL = URL(string: "http://localhost:8080/v1")!,
                apiKey: String? = nil,
                headers: [String: String] = [:]) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.headers = headers
    }

    public static let `default` = OpenAIConnection()

    /// Redacted form of `apiKey` for log lines.
    public var redactedKey: String {
        guard let k = apiKey, !k.isEmpty else { return "(none)" }
        let prefix = k.prefix(3)
        return "\(prefix)***"
    }
}

/// Image-handling options for the OpenAI-compatible client. Mirrors
/// `OllamaImageOptions` so the pipeline downsize policy stays identical
/// across providers (1024 px long edge, JPEG q=0.8 by default).
public struct OpenAIImageOptions: Sendable {
    public var downsize: Bool
    public var maxPixelSize: Int
    public var jpegQuality: CGFloat
    /// Cap on the model's generated output length. mlx-vlm and LM Studio
    /// default to tiny caps (~100 tokens) which truncates our DESCRIPTION +
    /// TAGS output mid-sentence; 1024 gives enough headroom.
    public var maxTokens: Int
    /// Sampling temperature. We want deterministic, description-shaped
    /// output, so a low value is appropriate.
    public var temperature: Double

    public init(downsize: Bool = true,
                maxPixelSize: Int = 1024,
                jpegQuality: CGFloat = 0.8,
                maxTokens: Int = 1024,
                temperature: Double = 0.3) {
        self.downsize = downsize
        self.maxPixelSize = maxPixelSize
        self.jpegQuality = jpegQuality
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// HTTP client for OpenAI-compatible chat completions endpoints. Talks to
/// `POST /chat/completions` with a `messages` array containing a text part
/// and (optionally) an `image_url` part encoded as a base64 data URL.
///
/// Model discovery hits `GET /models`. Preflight = listModels + name check,
/// same semantics as `OllamaClient.preflight`.
public final class OpenAIClient: LLMClient {

    public let connection: OpenAIConnection
    public let session: URLSession
    public var imageOptions: OpenAIImageOptions

    public var providerLabel: String { "openai-compatible" }

    public init(connection: OpenAIConnection = .default,
                timeoutSeconds: TimeInterval = 1800,
                imageOptions: OpenAIImageOptions = OpenAIImageOptions()) {
        self.connection = connection
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        self.session = URLSession(configuration: config)
        self.imageOptions = imageOptions
    }

    public var baseURL: URL { connection.baseURL }

    // MARK: - Auth

    private func applyAuth(to req: inout URLRequest) {
        if let key = connection.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in connection.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
    }

    /// Build a URL against `baseURL`. Both `/v1` and non-`/v1`-suffixed base
    /// URLs are accepted; the caller passes the tail (`models`, `chat/completions`).
    private func endpointURL(_ tail: String) -> URL {
        baseURL.appendingPathComponent(tail)
    }

    // MARK: - listModels

    public func listModels() async throws -> [LLMModel] {
        var req = URLRequest(url: endpointURL("models"))
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
        // OpenAI shape: {"object": "list", "data": [{"id": "...", ...}, ...]}
        // Some servers return {"models": [...]} — accept both.
        let entries: [[String: Any]]
        if let d = obj["data"] as? [[String: Any]] {
            entries = d
        } else if let m = obj["models"] as? [[String: Any]] {
            entries = m
        } else {
            throw PhotoSnailError.ollamaResponseParseFailed("listModels: missing 'data' array")
        }

        return entries.compactMap { entry in
            // OpenAI uses "id"; Ollama-style fallbacks use "name".
            guard let name = (entry["id"] as? String) ?? (entry["name"] as? String) else {
                return nil
            }
            return LLMModel(name: name, sizeBytes: nil, modifiedAt: nil)
        }
    }

    // MARK: - Preflight

    public func preflight(model: String) async -> LLMPreflightResult {
        let models: [LLMModel]
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

    // MARK: - Text-only generation

    public func generateText(model: String, prompt: String) async throws -> LLMTextResult {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt],
            ],
            "max_tokens": imageOptions.maxTokens,
            "temperature": imageOptions.temperature,
            "stream": false,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: endpointURL("chat/completions"))
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

        let content = try Self.parseChatCompletionContent(data)
        return LLMTextResult(model: model, response: content, elapsedSeconds: elapsed)
    }

    // MARK: - Image + text generation

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

        let dataURL = "data:image/jpeg;base64,\(sendData.base64EncodedString())"

        // OpenAI vision content schema: an array with text + image_url parts.
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": dataURL]],
                    ],
                ],
            ],
            "max_tokens": imageOptions.maxTokens,
            "temperature": imageOptions.temperature,
            "stream": false,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: endpointURL("chat/completions"))
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

        let (content, promptTokens, evalTokens) = try Self.parseChatCompletionContentWithUsage(data)
        let parsed = CaptionParser.parse(content)

        return CaptionResult(
            model: model,
            description: parsed.description,
            tags: parsed.tags,
            rawResponse: content,
            elapsedSeconds: elapsed,
            promptEvalTokens: promptTokens,
            promptEvalSeconds: nil,
            evalTokens: evalTokens,
            evalSeconds: nil,
            loadSeconds: nil,
            imageBytesSent: sendData.count,
            imagePixelWidth: pixelW,
            imagePixelHeight: pixelH
        )
    }

    // MARK: - Response parsing

    /// Extract the first choice's `message.content` string from a chat
    /// completions response body.
    private static func parseChatCompletionContent(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhotoSnailError.ollamaResponseParseFailed("not a JSON object")
        }
        guard let choices = obj["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw PhotoSnailError.ollamaResponseParseFailed("missing 'choices' array")
        }
        let first = choices[0]
        if let msg = first["message"] as? [String: Any] {
            // Some servers return `content` as a string; others (rare) as an array of parts.
            if let s = msg["content"] as? String {
                return s
            }
            if let parts = msg["content"] as? [[String: Any]] {
                let joined = parts.compactMap { $0["text"] as? String }.joined()
                if !joined.isEmpty { return joined }
            }
        }
        // LM Studio / some forks return `text` at the top of the choice.
        if let text = first["text"] as? String {
            return text
        }
        throw PhotoSnailError.ollamaResponseParseFailed("missing 'message.content'")
    }

    private static func parseChatCompletionContentWithUsage(_ data: Data) throws -> (content: String, promptTokens: Int?, completionTokens: Int?) {
        let content = try parseChatCompletionContent(data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (content, nil, nil)
        }
        let usage = obj["usage"] as? [String: Any]
        let p = usage?["prompt_tokens"] as? Int
        let c = usage?["completion_tokens"] as? Int
        return (content, p, c)
    }
}
