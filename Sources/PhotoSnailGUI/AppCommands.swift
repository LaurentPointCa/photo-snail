import SwiftUI

/// Shared observable for menu-driven actions that need to reach into a
/// specific window scene (e.g. triggering the Settings sheet from the
/// app-level menubar). The pattern mirrors `Localizer.pendingLanguageChange`
/// — the menu sets a flag, the owning view observes and responds.
@Observable
@MainActor
final class AppCommands {
    static let shared = AppCommands()
    private init() {}

    /// When true, LibraryWindow opens the Settings sheet and resets this back
    /// to false. The flag is the entire protocol — no payload, no callback.
    var pendingSettingsOpen: Bool = false
}
