import SwiftUI

struct StatusBar: View {
    let engine: ProcessingEngine

    var body: some View {
        HStack(spacing: 16) {
            StatBox(label: "Total", value: engine.totalCount, color: .secondary)
            StatBox(label: "Done", value: engine.doneCount, color: .green)
            StatBox(label: "Pending", value: engine.pendingCount, color: .blue)
            StatBox(label: "Failed", value: engine.failedCount, color: .red)

            Spacer()

            if engine.state == .running || engine.state == .paused {
                VStack(alignment: .trailing, spacing: 2) {
                    if engine.photosPerHour > 0 {
                        Text("\(String(format: "%.0f", engine.photosPerHour)) photos/hr")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("ETA: \(engine.etaString)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if engine.totalCount > 0 {
                let progress = Double(engine.doneCount) / Double(engine.totalCount)
                ProgressView(value: progress)
                    .frame(width: 120)
            }
        }
    }
}

private struct StatBox: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }
}
