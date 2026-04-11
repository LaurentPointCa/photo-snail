import SwiftUI

struct FailureListView: View {
    let engine: ProcessingEngine
    @State private var selectedID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Failed")
                    .font(.headline)
                Spacer()
                Text("\(engine.failures.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red.opacity(0.15)))
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(engine.failures, selection: $selectedID) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(failure.id.prefix(8)) + "...")
                        .font(.system(.caption, design: .monospaced))
                    Text(failure.error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)

            if let selectedID = selectedID,
               let failure = engine.failures.first(where: { $0.id == selectedID }) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Error Detail")
                        .font(.caption.bold())
                    Text(failure.error)
                        .font(.caption2)
                        .textSelection(.enabled)
                        .frame(maxHeight: 60)
                    Text("Attempts: \(failure.attempts)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") {
                            Task { await engine.retryFailed(failure.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Retry All") {
                            Task { await engine.retryAllFailed() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
            }
        }
    }
}
