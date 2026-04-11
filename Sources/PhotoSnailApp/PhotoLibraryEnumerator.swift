import Foundation
import Photos
import PhotoSnailCore

/// Discovers unprocessed image assets in the Photo Library.
///
/// On first run (empty queue), bootstraps by querying Photos.app via AppleScript
/// for assets whose description already contains the sentinel marker. Those are
/// added to the queue as `done` so they're skipped. All remaining image assets
/// are returned for processing.
enum PhotoLibraryEnumerator {

    /// Returns localIdentifiers of image assets that are NOT yet in the queue as `done`.
    /// Also enqueues any previously-processed assets (found via sentinel) as `done` in the queue.
    static func fetchUnprocessedIdentifiers(
        queue: AssetQueue,
        sentinel: String
    ) async throws -> [String] {
        // 1. Get all image assets from PhotoKit
        let allAssets = PhotoLibrary.fetchAllImageAssets()
        var allIds: [String] = []
        allAssets.enumerateObjects { asset, _, _ in
            allIds.append(asset.localIdentifier)
        }
        eprint("library: \(allIds.count) image assets total")

        // 2. Enqueue all into the queue (idempotent — existing rows untouched)
        try await queue.enqueue(allIds)

        // 3. Check queue stats — if there are already `done` rows, skip sentinel bootstrap
        let stats = try await queue.stats()
        if stats.done == 0 && stats.pending == allIds.count {
            // First run with a fresh queue. Bootstrap: find assets already tagged
            // in a prior queue DB (or manually) by querying Photos.app's descriptions.
            eprint("bootstrap: querying Photos.app for existing sentinel markers...")
            let (markedIds, ms) = try await MainActor.run {
                try PhotosScripter.findAssetsByDescriptionMarker(sentinel)
            }
            eprint("bootstrap: found \(markedIds.count) already-processed assets (\(String(format: "%.0f", ms)) ms)")

            // markedIds are Photos.app ids (UUID/L0/001 format). Match them to
            // localIdentifiers by UUID prefix.
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
                eprint("bootstrap: marked \(bootstrapped) assets as done in queue")
            }
        }

        // 4. Return the count of pending assets (the queue handles the rest)
        let finalStats = try await queue.stats()
        eprint("queue: \(finalStats.pending) pending, \(finalStats.done) done, \(finalStats.failed) failed")
        return [] // QueueRunner pulls from queue.claimNext(), not from this list
    }
}

private func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
