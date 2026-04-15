import Foundation
import AppKit

/// Observes macOS screen-lock / screen-unlock events via
/// `DistributedNotificationCenter`. These notifications are the canonical
/// way to react to the user locking their Mac — they fire for both the
/// Cmd+Ctrl+Q hotkey and screensaver-driven locks.
///
/// Notification names (legacy Darwin-style strings, not namespaced through
/// Apple's newer APIs):
///   - com.apple.screenIsLocked
///   - com.apple.screenIsUnlocked
///
/// Usage:
///   let watcher = LockWatcher(
///       onLock: { /* start queue */ },
///       onUnlock: { /* pause queue */ }
///   )
///   // hold the reference for the lifetime you want callbacks
///   watcher.stop()  // optional; deinit also tears down
///
/// MainActor-isolated because the callbacks typically touch UI state.
@MainActor
final class LockWatcher {

    private let onLock: () -> Void
    private let onUnlock: () -> Void

    private var lockToken: NSObjectProtocol?
    private var unlockToken: NSObjectProtocol?

    init(onLock: @escaping () -> Void, onUnlock: @escaping () -> Void) {
        self.onLock = onLock
        self.onUnlock = onUnlock

        let center = DistributedNotificationCenter.default()
        self.lockToken = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onLock()
        }
        self.unlockToken = center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onUnlock()
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        if let lockToken {
            center.removeObserver(lockToken)
            self.lockToken = nil
        }
        if let unlockToken {
            center.removeObserver(unlockToken)
            self.unlockToken = nil
        }
    }

    deinit {
        // Centers are thread-safe for removeObserver; safe to call from
        // the nonisolated deinit context.
        let center = DistributedNotificationCenter.default()
        if let lockToken { center.removeObserver(lockToken) }
        if let unlockToken { center.removeObserver(unlockToken) }
    }
}
