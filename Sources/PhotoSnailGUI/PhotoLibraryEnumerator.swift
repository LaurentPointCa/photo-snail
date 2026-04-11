import Foundation
import Photos
import PhotoSnailCore

/// Discovers unprocessed image assets in the Photo Library.
/// GUI variant: logs via a closure instead of stderr.
enum PhotoLibraryEnumerator {

    static func fetchUnprocessedIdentifiers(
        queue: AssetQueue,
        sentinel: String,
        log: @escaping (String) -> Void = { _ in }
    ) async throws -> Int {
        let allAssets = PhotoLibrary.fetchAllImageAssets()
        var allIds: [String] = []
        allAssets.enumerateObjects { asset, _, _ in
            allIds.append(asset.localIdentifier)
        }
        log("Library: \(allIds.count) image assets")

        try await queue.enqueue(allIds)

        let stats = try await queue.stats()
        if stats.done == 0 && stats.pending == allIds.count {
            log("Bootstrapping sentinel detection...")
            let (markedIds, ms) = try await MainActor.run {
                try PhotosScripter.findAssetsByDescriptionMarker(sentinel)
            }
            log("Found \(markedIds.count) already-processed assets (\(String(format: "%.0f", ms)) ms)")

            if !markedIds.isEmpty {
                let markedPrefixes = Set(markedIds.map { PhotoLibrary.uuidPrefix($0) })
                var bootstrapped = 0
                for localId in allIds {
                    let prefix = PhotoLibrary.uuidPrefix(localId)
                    if markedPrefixes.contains(prefix) {
                        try? await queue.markBootstrapped(localId)
                        bootstrapped += 1
                    }
                }
                log("Marked \(bootstrapped) assets as done")
            }
        }

        let finalStats = try await queue.stats()
        log("\(finalStats.pending) pending, \(finalStats.done) done, \(finalStats.failed) failed")
        return finalStats.pending
    }
}
