import SwiftUI

@main
struct PhotoSnailApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // Big enough that the new library window doesn't clip. The old
        // ContentView has its own internal min frame and will look fine
        // letterboxed inside the larger window.
        .defaultSize(width: 1200, height: 800)
    }
}

/// Branches between the old batch-monitor UI (`ContentView`) and the new
/// library browser (`LibraryWindow`). The new UI is opt-in during development:
/// set `PHOTO_SNAIL_NEW_UI=1` in the environment before launching the app.
/// Phase 6 will flip the default and delete the old UI.
struct RootView: View {
    private let useNewUI: Bool = {
        ProcessInfo.processInfo.environment["PHOTO_SNAIL_NEW_UI"] == "1"
    }()

    var body: some View {
        if useNewUI {
            LibraryWindow()
        } else {
            ContentView()
        }
    }
}
