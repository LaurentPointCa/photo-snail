import SwiftUI

@main
struct PhotoSnailApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryWindow()
        }
        .defaultSize(width: 1400, height: 900)
    }
}
