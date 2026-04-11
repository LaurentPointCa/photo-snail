import SwiftUI

/// Top half: last completed photo with description and tags.
struct CompletedPhotoView: View {
    let engine: ProcessingEngine

    var body: some View {
        if engine.completedDescription.isEmpty {
            // Nothing completed yet
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Completed photos will appear here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 16) {
                // Thumbnail
                if let thumb = engine.completedThumbnail {
                    Image(decorative: thumb, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 280, maxHeight: 260)
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 200, height: 150)
                }

                // Description + tags
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Last Completed")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        Text(engine.completedDescription)
                            .font(.body)
                            .textSelection(.enabled)

                        if !engine.completedTags.isEmpty {
                            TagFlow(tags: engine.completedTags)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Bottom half: photo currently being processed by the model.
struct CurrentPhotoView: View {
    let engine: ProcessingEngine

    var body: some View {
        HStack(spacing: 16) {
            if let thumb = engine.currentThumbnail {
                Image(decorative: thumb, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 200, maxHeight: 160)
                    .opacity(0.85)
            } else if engine.state == .running {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 160, height: 120)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 160, height: 120)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Processing")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if let id = engine.currentPhotoID {
                    Text(String(id.prefix(36)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if engine.state == .running {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Generating description...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if engine.state == .paused {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if engine.state == .idle {
                    Text("Waiting to start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.background.opacity(0.5))
    }
}

// MARK: - Tag Flow

struct TagFlow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(tag.hasPrefix("ai:") ? Color.orange.opacity(0.15) : Color.blue.opacity(0.1))
                    )
                    .foregroundStyle(tag.hasPrefix("ai:") ? .orange : .primary)
            }
        }
    }
}

/// Simple flow layout for tag chips (macOS 14+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for row in rows {
            height += row.height + (height > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        var idx = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
                idx += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row { let count: Int; let height: CGFloat }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentCount = 0
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if currentCount > 0 && currentWidth + spacing + size.width > maxWidth {
                rows.append(Row(count: currentCount, height: currentHeight))
                currentCount = 0
                currentWidth = 0
                currentHeight = 0
            }
            currentWidth += (currentCount > 0 ? spacing : 0) + size.width
            currentHeight = max(currentHeight, size.height)
            currentCount += 1
        }
        if currentCount > 0 {
            rows.append(Row(count: currentCount, height: currentHeight))
        }
        return rows
    }
}
