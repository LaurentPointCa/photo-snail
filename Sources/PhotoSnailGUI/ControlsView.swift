import SwiftUI

struct ControlsView: View {
    let engine: ProcessingEngine

    var body: some View {
        HStack(spacing: 12) {
            switch engine.state {
            case .idle:
                Button {
                    Task { await engine.start() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .enumerating:
                ProgressView()
                    .controlSize(.small)
                Text("Enumerating library...")
                    .foregroundStyle(.secondary)

            case .running:
                Button {
                    engine.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                ProgressView()
                    .controlSize(.small)

            case .paused:
                Button {
                    engine.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                Text("Complete")
                    .font(.headline)
            }

            Spacer()

            Text(engine.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
