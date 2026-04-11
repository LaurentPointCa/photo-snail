import SwiftUI

struct ContentView: View {
    @State private var engine = ProcessingEngine()
    @State private var showFailures = false

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            StatusBar(engine: engine)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            Divider()

            // Main content: completed on top, current on bottom
            HSplitView {
                VStack(spacing: 0) {
                    // Top half: last completed photo + description + tags
                    CompletedPhotoView(engine: engine)

                    Divider()

                    // Bottom half: currently processing photo
                    CurrentPhotoView(engine: engine)
                }
                .frame(minWidth: 400)

                if showFailures && engine.failedCount > 0 {
                    FailureListView(engine: engine)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 350)
                }
            }

            Divider()

            // Controls
            ControlsView(engine: engine)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .frame(minWidth: 700, minHeight: 550)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showFailures) {
                    Label("Failures", systemImage: "exclamationmark.triangle")
                }
                .disabled(engine.failedCount == 0)
            }
        }
        .task {
            await engine.loadInitialStats()
        }
    }
}
