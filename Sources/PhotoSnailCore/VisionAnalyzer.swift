import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Runs Apple Vision pre-pass on an image and returns structured findings.
public final class VisionAnalyzer {

    public struct Options {
        /// Minimum classification confidence to keep a label.
        public var classificationThreshold: Float = 0.10
        /// Maximum number of classification labels to return.
        public var maxClassifications: Int = 20
        /// OCR recognition level.
        public var ocrAccurate: Bool = true

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Loads an image from disk along with its EXIF orientation, so Vision sees the upright pixels.
    public static func loadCGImageWithOrientation(_ path: String) -> (CGImage, CGImagePropertyOrientation, Int, Int)? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return extractFromSource(src)
    }

    /// Loads an image from in-memory data along with its EXIF orientation.
    public static func loadCGImageWithOrientation(data: Data) -> (CGImage, CGImagePropertyOrientation, Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return extractFromSource(src)
    }

    private static func extractFromSource(_ src: CGImageSource) -> (CGImage, CGImagePropertyOrientation, Int, Int)? {
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var orientation: CGImagePropertyOrientation = .up
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let raw = props[kCGImagePropertyOrientation] as? UInt32,
           let parsed = CGImagePropertyOrientation(rawValue: raw) {
            orientation = parsed
        }
        return (cg, orientation, cg.width, cg.height)
    }

    /// Analyze an image from a file path.
    public func analyze(imagePath: String) throws -> VisionFindings {
        guard let (cg, orientation, _, _) = Self.loadCGImageWithOrientation(imagePath) else {
            throw PhotoSnailError.imageLoadFailed(imagePath)
        }
        return try analyzeCore(cgImage: cg, orientation: orientation)
    }

    /// Analyze an image from in-memory data (e.g. from PHImageManager).
    public func analyze(imageData: Data) throws -> VisionFindings {
        guard let (cg, orientation, _, _) = Self.loadCGImageWithOrientation(data: imageData) else {
            throw PhotoSnailError.imageLoadFailed("in-memory data (\(imageData.count) bytes)")
        }
        return try analyzeCore(cgImage: cg, orientation: orientation)
    }

    private func analyzeCore(cgImage cg: CGImage, orientation: CGImagePropertyOrientation) throws -> VisionFindings {
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        let t0 = Date()

        // 1. Classification
        var classifications: [VisionLabel] = []
        do {
            let req = VNClassifyImageRequest()
            try handler.perform([req])
            if let results = req.results {
                classifications = results
                    .filter { $0.confidence >= options.classificationThreshold }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(options.maxClassifications)
                    .map { VisionLabel(identifier: $0.identifier, confidence: $0.confidence) }
            }
        }

        // 2. Animals
        var animals: [DetectedRegion] = []
        do {
            let req = VNRecognizeAnimalsRequest()
            try handler.perform([req])
            if let results = req.results {
                for r in results {
                    let topLabel = r.labels.max(by: { $0.confidence < $1.confidence })
                    animals.append(DetectedRegion(
                        label: topLabel?.identifier ?? "animal",
                        confidence: topLabel?.confidence ?? 0,
                        boundingBox: r.boundingBox
                    ))
                }
            }
        }

        // 3. Faces
        var faces: [DetectedRegion] = []
        do {
            let req = VNDetectFaceRectanglesRequest()
            try handler.perform([req])
            if let results = req.results {
                for r in results {
                    faces.append(DetectedRegion(
                        label: "face",
                        confidence: r.confidence,
                        boundingBox: r.boundingBox
                    ))
                }
            }
        }

        // 4. OCR
        var ocr: [String] = []
        do {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = options.ocrAccurate ? .accurate : .fast
            req.usesLanguageCorrection = true
            try handler.perform([req])
            if let results = req.results {
                for r in results {
                    if let top = r.topCandidates(1).first?.string {
                        let trimmed = top.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            ocr.append(trimmed)
                        }
                    }
                }
            }
        }

        let elapsed = Date().timeIntervalSince(t0)
        return VisionFindings(
            classifications: classifications,
            animals: animals,
            faces: faces,
            ocrText: ocr,
            elapsedSeconds: elapsed
        )
    }
}
