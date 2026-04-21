import Foundation
import AppKit

/// Shared observable bridge between the Tools windows and the main
/// LibraryWindow. Each tool window is its own SwiftUI scene (spawned via
/// `openWindow(id:)`) so it doesn't share the main window's `@State
/// LibraryStore` instance. Rather than plumb a cross-window reference
/// through the scene graph, tools publish "reveal" requests on this
/// singleton and the main window observes them — same pattern as
/// `AppCommands.pendingSettingsOpen` and `Localizer.pendingLanguageChange`.
///
/// The reveal flow, end to end:
///   1. User right-clicks a finding in a tool window → picks "Show in
///      PhotoSnail library".
///   2. Tool window sets `pendingReveal = <asset id>`.
///   3. `LibraryWindow.onChange(of: ...)` fires, switches filter to `.all`,
///      replaces the selection with the id, flips `scrollOnSelectionChange`
///      so the grid centers the cell, and raises the main window.
///   4. Handler sets `pendingReveal = nil` so a subsequent identical-id
///      reveal re-triggers the observer.
@Observable
@MainActor
final class ToolsRouter {
    static let shared = ToolsRouter()
    private init() {}

    /// Last-requested asset id to reveal in the main library window. Nil
    /// when no reveal is pending. The setter is the whole API — observers
    /// clear it after consuming.
    var pendingReveal: String? = nil

    /// Raise the main library window to the front. Called right after
    /// setting `pendingReveal` so the user's eye lands on the inspector
    /// without an extra click. Finds the key window by title match
    /// (brittle, but there's only one main scene) falling back to the
    /// first non-panel NSWindow.
    func activateLibraryWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Find the main library window — it's a SwiftUI WindowGroup, so
        // the NSWindow class is something like SwiftUI.AppKitWindow. We
        // identify it by ruling out known auxiliary windows (tool windows,
        // log window, sheets, panels).
        let auxiliaryClasses = ["NSPanel", "AboutPanel"]
        let auxiliaryTitles = Set([
            "Logs",
            "Scan: Multi-segment descriptions",
            "Clean: Multi-segment descriptions",
            "Scan: Preserved original descriptions",
        ])
        let candidate = NSApp.windows.first { w in
            guard w.isVisible else { return false }
            if auxiliaryClasses.contains(where: { NSStringFromClass(type(of: w)).contains($0) }) {
                return false
            }
            if auxiliaryTitles.contains(w.title) { return false }
            return true
        }
        candidate?.makeKeyAndOrderFront(nil)
    }
}
