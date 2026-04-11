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

/// Minimal HTTP client for the Ollama /api/generate endpoint with image attachments.
public final class OllamaClient {

    public let baseURL: URL
    public let session: URLSession
    public var imageOptions: OllamaImageOptions

    public init(baseURL: URL = URL(string: "http://localhost:11434")!,
                timeoutSeconds: TimeInterval = 1800,
                imageOptions: OllamaImageOptions = OllamaImageOptions()) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        self.session = URLSession(configuration: config)
        self.imageOptions = imageOptions
    }

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
