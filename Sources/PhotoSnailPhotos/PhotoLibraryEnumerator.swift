import Foundation
import Photos
import PhotoSnailCore

/// Discovers unprocessed image assets in the Photo Library.
///
/// Enumeration is detached to a `.userInitiated` background task because
/// `PHFetchResult.enumerateObjects` pegs a core for multiple minutes on
/// large libraries (the 39 k-photo tester case). Safe per Apple's docs —
/// PHFetchResult is thread-safe.
///
/// Callers supply a `log` closure so the CLI can forward to stderr while
/// the GUI fans out to its structured LogStore.
public enum PhotoLibraryEnumerator {

    /// Walk the library, upsert every image asset into the queue, and (on
    /// a fresh queue with zero `done` rows) bootstrap-detect already-tagged
    /// assets by querying Photos.app for descriptions containing `sentinel`.
    /// Returns the number of `pending` rows the queue holds afterward.
    public static func fetchUnprocessedIdentifiers(
        queue: AssetQueue,
        sentinel: String,
        log: @escaping (String) -> Void = { _ in }
    ) async throws -> Int {
        let allIds: [String] = await Task.detached(priority: .userInitiated) {
            let allAssets = PhotoLibrary.fetchAllImageAssets()
            var ids: [String] = []
            allAssets.enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
            return ids
        }.value
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
