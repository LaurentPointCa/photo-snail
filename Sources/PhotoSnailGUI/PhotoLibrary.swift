import Foundation
import Photos
import PhotoSnailCore

/// PhotoKit helper: auth, fetch, enumeration, UUID prefix extraction.
///
/// PhotoKit's public API has NO read accessor for an asset's title,
/// description, or keywords. Those fields live in Photos.app's internal
/// Photos.sqlite. All description reads/writes go through PhotosScripter
/// via AppleScript — that's the whole reason Phase F uses scripting.
enum PhotoLibrary {

    /// Request read-write Photo Library authorization.
    static func requestAuth() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    struct AssetRow {
        let id: String
        let creationDate: Date?
        let mediaType: PHAssetMediaType
    }

    /// Return up to `n` most-recent image assets sorted by creation date descending.
    static func listFirst(n: Int) -> [AssetRow] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = max(1, n)
        let result = PHAsset.fetchAssets(with: .image, options: opts)
        var rows: [AssetRow] = []
        result.enumerateObjects { asset, _, _ in
            rows.append(AssetRow(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                mediaType: asset.mediaType
            ))
        }
        return rows
    }

    /// Fetch all image assets (no limit), sorted by creation date ascending.
    static func fetchAllImageAssets() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: .image, options: opts)
    }

    /// Fetch one asset by its full localIdentifier.
    static func fetch(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Strip the `/L0/001` suffix from `PHAsset.localIdentifier` to get the UUID
    /// prefix that Photos.app's AppleScript dictionary uses as the media item id.
    static func uuidPrefix(_ localIdentifier: String) -> String {
        if let slash = localIdentifier.firstIndex(of: "/") {
            return String(localIdentifier[..<slash])
        }
        return localIdentifier
    }

    /// Request image data + orientation for a PHAsset via PHImageManager.
    /// Returns nil data for cloud-only assets that haven't been downloaded.
    static func requestImageData(for asset: PHAsset) async throws -> (Data, CGImagePropertyOrientation) {
        try await withCheckedThrowingContinuation { cont in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, orientation, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: error)
                    return
                }
                guard let data = data else {
                    cont.resume(throwing: PhotoSnailError.imageLoadFailed(
                        "PHImageManager returned nil data for \(asset.localIdentifier)"))
                    return
                }
                cont.resume(returning: (data, orientation))
            }
        }
    }

    /// Human-readable label for PHAssetMediaType.
    static func mediaTypeLabel(_ t: PHAssetMediaType) -> String {
        switch t {
        case .image:   return "image"
        case .video:   return "video"
        case .audio:   return "audio"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    /// Human-readable label for an authorization status.
    static func authStatusLabel(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .limited:       return "limited"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }
}
