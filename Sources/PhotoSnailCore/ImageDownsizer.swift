import Foundation
import ImageIO
import CoreGraphics
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Downsizes an image to a JPEG with the long edge at most `maxPixelSize`.
/// Uses CGImageSource thumbnail APIs so EXIF orientation is baked into the pixels and
/// the original full-resolution image is never decoded into memory.
public struct ImageDownsizer {

    public struct Result {
        public let data: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let elapsedSeconds: Double
    }

    /// Downsize from a file path on disk.
    public static func downsizedJPEG(path: String,
                                     maxPixelSize: Int = 1024,
                                     quality: CGFloat = 0.8) throws -> Result {
        let t0 = Date()
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoSnailError.imageLoadFailed("CGImageSource failed for \(path)")
        }
        return try encodeThumb(source: src, maxPixelSize: maxPixelSize, quality: quality, t0: t0, label: path)
    }

    /// Downsize from in-memory image data (e.g. from PHImageManager).
    public static func downsizedJPEG(data: Data,
                                     maxPixelSize: Int = 1024,
                                     quality: CGFloat = 0.8) throws -> Result {
        let t0 = Date()
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoSnailError.imageLoadFailed("CGImageSource failed for in-memory data (\(data.count) bytes)")
        }
        return try encodeThumb(source: src, maxPixelSize: maxPixelSize, quality: quality, t0: t0, label: "in-memory")
    }

    // MARK: - Shared thumbnail + JPEG encode

    private static func encodeThumb(source: CGImageSource,
                                    maxPixelSize: Int,
                                    quality: CGFloat,
                                    t0: Date,
                                    label: String) throws -> Result {
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            throw PhotoSnailError.imageLoadFailed("thumbnail creation failed for \(label)")
        }

        let mutableData = NSMutableData()
        let typeId: CFString
        #if canImport(UniformTypeIdentifiers)
        typeId = UTType.jpeg.identifier as CFString
        #else
        typeId = "public.jpeg" as CFString
        #endif
        guard let dest = CGImageDestinationCreateWithData(mutableData, typeId, 1, nil) else {
            throw PhotoSnailError.imageLoadFailed("CGImageDestination failed for \(label)")
        }
        let destOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, cg, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw PhotoSnailError.imageLoadFailed("JPEG encode failed for \(label)")
        }
        let elapsed = Date().timeIntervalSince(t0)
        return Result(
            data: mutableData as Data,
            pixelWidth: cg.width,
            pixelHeight: cg.height,
            elapsedSeconds: elapsed
        )
    }
}
