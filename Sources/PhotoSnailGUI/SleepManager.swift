import Foundation
import AppKit
import IOKit.pwr_mgt

/// Manages macOS sleep behaviour during processing:
///
/// 1. **IOKit power assertion** (`kIOPMAssertionTypeNoIdleSleep`) — prevents
///    the Mac from idle-sleeping while the worker is running. This is the
///    primary defence against the "lock → idle sleep → Ollama errors" bug.
///    Manual sleep (lid close, Apple menu → Sleep) is still allowed.
///
/// 2. **NSWorkspace sleep/wake observers** — safety net for forced sleep.
///    Fires `onSleep` before the system sleeps and `onWake` after it wakes
///    so the caller can pause/resume the worker gracefully.
///
/// Usage mirrors `LockWatcher`: create once, hold the reference, call
/// `preventIdleSleep` / `allowIdleSleep` around processing runs.
///
/// MainActor-isolated because the callbacks touch engine state.
@MainActor
final class SleepManager {

    private let onSleep: () -> Void
    private let onWake: () -> Void

    private var sleepToken: NSObjectProtocol?
    private var wakeToken: NSObjectProtocol?

    private var assertionID: IOPMAssertionID = 0
    private var assertionHeld = false

    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake

        let center = NSWorkspace.shared.notificationCenter
        self.sleepToken = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onSleep() }
        }
        self.wakeToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onWake() }
        }
    }

    /// Create a power assertion that prevents macOS idle sleep.
    /// Safe to call multiple times — no-op if already held.
    func preventIdleSleep(reason: String = "PhotoSnail processing batch") {
        guard !assertionHeld else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        assertionHeld = (result == kIOReturnSuccess)
    }

    /// Release the idle-sleep power assertion. Safe to call when not held.
    func allowIdleSleep() {
        guard assertionHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionHeld = false
    }

    func stop() {
        allowIdleSleep()
        let center = NSWorkspace.shared.notificationCenter
        if let sleepToken { center.removeObserver(sleepToken) }
        if let wakeToken { center.removeObserver(wakeToken) }
        sleepToken = nil
        wakeToken = nil
    }

    deinit {
        if assertionHeld { IOPMAssertionRelease(assertionID) }
        let center = NSWorkspace.shared.notificationCenter
        if let sleepToken { center.removeObserver(sleepToken) }
        if let wakeToken { center.removeObserver(wakeToken) }
    }
}
