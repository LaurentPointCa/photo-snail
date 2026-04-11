import Foundation
import CoreGraphics

/// One classification label produced by Apple Vision.
public struct VisionLabel: Codable, Sendable {
    public let identifier: String
    public let confidence: Float

    public init(identifier: String, confidence: Float) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// One detected animal/face region.
public struct DetectedRegion: Codable, Sendable {
    public let label: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(label: String, confidence: Float, boundingBox: CGRect) {
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Output of the Apple Vision pre-pass.
public struct VisionFindings: Codable, Sendable {
    public let classifications: [VisionLabel]
    public let animals: [DetectedRegion]
    public let faces: [DetectedRegion]
    public let ocrText: [String]
    public let elapsedSeconds: Double

    public init(
        classifications: [VisionLabel],
        animals: [DetectedRegion],
        faces: [DetectedRegion],
        ocrText: [String],
        elapsedSeconds: Double
    ) {
        self.classifications = classifications
        self.animals = animals
        self.faces = faces
        self.ocrText = ocrText
        self.elapsedSeconds = elapsedSeconds
    }

    public static let empty = VisionFindings(
        classifications: [],
        animals: [],
        faces: [],
        ocrText: [],
        elapsedSeconds: 0
    )
}

/// Result of one LLM caption call.
public struct CaptionResult: Codable, Sendable {
    public let model: String
    public let description: String
    public let tags: [String]
    public let rawResponse: String
    public let elapsedSeconds: Double
    public let promptEvalTokens: Int?
    public let promptEvalSeconds: Double?
    public let evalTokens: Int?
    public let evalSeconds: Double?
    public let loadSeconds: Double?
    public let imageBytesSent: Int
    public let imagePixelWidth: Int
    public let imagePixelHeight: Int

    public init(
        model: String,
        description: String,
        tags: [String],
        rawResponse: String,
        elapsedSeconds: Double,
        promptEvalTokens: Int? = nil,
        promptEvalSeconds: Double? = nil,
        evalTokens: Int? = nil,
        evalSeconds: Double? = nil,
        loadSeconds: Double? = nil,
        imageBytesSent: Int = 0,
        imagePixelWidth: Int = 0,
        imagePixelHeight: Int = 0
    ) {
        self.model = model
        self.description = description
        self.tags = tags
        self.rawResponse = rawResponse
        self.elapsedSeconds = elapsedSeconds
        self.promptEvalTokens = promptEvalTokens
        self.promptEvalSeconds = promptEvalSeconds
        self.evalTokens = evalTokens
        self.evalSeconds = evalSeconds
        self.loadSeconds = loadSeconds
        self.imageBytesSent = imageBytesSent
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
    }
}

/// Final result of the hybrid pipeline for one image.
public struct PipelineResult: Codable, Sendable {
    public let imagePath: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let vision: VisionFindings
    public let prompt: String
    public let caption: CaptionResult
    public let mergedTags: [String]
    public let totalElapsedSeconds: Double

    public init(
        imagePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        vision: VisionFindings,
        prompt: String,
        caption: CaptionResult,
        mergedTags: [String],
        totalElapsedSeconds: Double
    ) {
        self.imagePath = imagePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.vision = vision
        self.prompt = prompt
        self.caption = caption
        self.mergedTags = mergedTags
        self.totalElapsedSeconds = totalElapsedSeconds
    }
}

public enum PhotoSnailError: Error, CustomStringConvertible {
    case imageLoadFailed(String)
    case ollamaRequestFailed(String)
    case ollamaResponseParseFailed(String)

    public var description: String {
        switch self {
        case .imageLoadFailed(let s): return "imageLoadFailed: \(s)"
        case .ollamaRequestFailed(let s): return "ollamaRequestFailed: \(s)"
        case .ollamaResponseParseFailed(let s): return "ollamaResponseParseFailed: \(s)"
        }
    }

    /// Whether the queue should retry this error after a backoff.
    /// `.ollamaRequestFailed` covers HTTP/timeout/network blips and is the only retriable case.
    /// `.imageLoadFailed` (file missing) and `.ollamaResponseParseFailed` (model produced
    /// non-conforming output — rare after Phase D) are treated as permanent.
    public var isRetriable: Bool {
        switch self {
        case .imageLoadFailed:           return false
        case .ollamaRequestFailed:       return true
        case .ollamaResponseParseFailed: return false
        }
    }

    /// Compact one-line form for storing in the queue's `error` column.
    public var shortMessage: String { description }
}
