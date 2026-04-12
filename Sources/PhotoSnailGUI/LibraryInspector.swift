import SwiftUI
import Photos
import CoreLocation
import PhotoSnailCore

// MARK: - Inspector root

/// Right-hand pane of the library window. Shows everything we know about
/// one selected asset: the photo itself, PhotoKit identity, the editable
/// description + tags, processing provenance (exact model, sentinel,
/// timings), the Vision side-channel findings, and a collapsible raw-row
/// "Developer" section for debugging.
///
/// Phase 3 deliberately punts on three things:
///   - Reverse geocoding the location → Phase 7 polish.
///   - Multi-tag filtering → Phase 4 expands the single-tag filter into
///     AND-composed active filters with a popular-tags picker.
///   - Bulk / multi-selection detail view → Phase 5.
///
/// The trick that makes this view simple: the wrapper `LibraryInspector`
/// passes the selected id to `InspectorContent(...).id(id)`, which forces
/// SwiftUI to instantiate a fresh `InspectorContent` every time the
/// selection changes. That means every `@State` on `InspectorContent`
/// (draft text, hero image, albums) is reset at the right moment without
/// any manual change-tracking.
struct LibraryInspector: View {
    @Bindable var store: LibraryStore

    var body: some View {
        Group {
            switch store.selection.count {
            case 0:
                ContentUnavailableView(
                    "No selection",
                    systemImage: "photo",
                    description: Text("Select a photo in the grid to inspect it.")
                )
            case 1:
                // `selection.first!` is safe inside `count == 1`.
                let id = store.selection.first!
                InspectorContent(store: store, assetId: id)
                    .id(id)
            default:
                MultiSelectionSummary(store: store)
            }
        }
        .navigationTitle("Inspector")
    }
}

// MARK: - Multi-selection summary

/// Shown when the user has 2+ photos selected. Surfaces aggregate
/// metadata and directs the user to the bulk action bar above the grid
/// for operations. Intentionally simple — this isn't a second place
/// to do bulk ops, just a summary of what's selected.
private struct MultiSelectionSummary: View {
    @Bindable var store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SurfaceCard(spacing: Spacing.md) {
                    Text("\(store.selection.count) photos selected")
                        .font(AppFont.display)
                        .foregroundStyle(AppColor.textPrimary)
                    thumbFilmstrip
                }

                SurfaceCard { statsSection }

                if !commonTags.isEmpty {
                    SurfaceCard { commonTagsSection }
                }

                if !modelBreakdown.isEmpty {
                    SurfaceCard { modelBreakdownSection }
                }

                Text("Use the bulk action bar above the grid to re-process, clear, copy tags, or export.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sm)

                Spacer(minLength: 0)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Filmstrip

    @ViewBuilder
    private var thumbFilmstrip: some View {
        let ids = Array(store.selection.sorted().prefix(12))
        let remaining = store.selection.count - ids.count
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(ids, id: \.self) { id in
                    ThumbnailCell(id: id, row: store.rows[id], isSelected: true, size: 72)
                }
                if remaining > 0 {
                    Text("+\(remaining)")
                        .font(AppFont.bodyEmphasized)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, height: 72)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous)
                                .fill(AppColor.surfaceSunken)
                        )
                }
            }
        }
    }

    // MARK: Aggregate stats

    private var countsByStatus: (tagged: Int, pending: Int, failed: Int, untouched: Int) {
        var tagged = 0, pending = 0, failed = 0, untouched = 0
        for id in store.selection {
            guard let row = store.rows[id] else { untouched += 1; continue }
            switch row.status {
            case "done":                    tagged += 1
            case "pending", "in_progress":  pending += 1
            case "failed":                  failed += 1
            default:                        untouched += 1
            }
        }
        return (tagged, pending, failed, untouched)
    }

    private var dateRange: (earliest: Int64?, latest: Int64?) {
        var earliest: Int64? = nil
        var latest: Int64? = nil
        for id in store.selection {
            guard let ts = store.rows[id]?.processedAt else { continue }
            if earliest == nil || ts < earliest! { earliest = ts }
            if latest == nil || ts > latest! { latest = ts }
        }
        return (earliest, latest)
    }

    @ViewBuilder
    private var statsSection: some View {
        let counts = countsByStatus
        EyebrowLabel("Status")
        VStack(alignment: .leading, spacing: Spacing.xs) {
            statRow("Tagged", counts.tagged, tint: AppColor.statusDone)
            statRow("Pending", counts.pending, tint: AppColor.statusPending)
            statRow("Failed", counts.failed, tint: AppColor.statusFailed)
            statRow("Untouched", counts.untouched, tint: AppColor.statusUntouched)
        }

        let range = dateRange
        if let e = range.earliest, let l = range.latest, e != 0 || l != 0 {
            EyebrowLabel("Processed")
                .padding(.top, Spacing.sm)
            Text("\(formatTimestamp(e)) → \(formatTimestamp(l))")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ count: Int, tint: Color) -> some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .font(AppFont.label)
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            Text("\(count)")
                .font(AppFont.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Common tags

    private var commonTags: [String] {
        // Intersect every row's tag set. Rows without any tags drop out
        // of the intersection entirely.
        var iter = store.selection.makeIterator()
        guard let firstId = iter.next(), let firstRow = store.rows[firstId] else { return [] }
        var common = Set(firstRow.tags)
        while let id = iter.next() {
            guard let row = store.rows[id] else { return [] }
            common.formIntersection(row.tags)
            if common.isEmpty { return [] }
        }
        return common.sorted()
    }

    @ViewBuilder
    private var commonTagsSection: some View {
        EyebrowLabel("Tags in every selected photo")
        ChipFlowLayout(spacing: 8, runSpacing: 8) {
            ForEach(commonTags, id: \.self) { tag in
                CommonTagChip(tag: tag) {
                    store.toggleTagFilter(tag)
                }
            }
        }
    }

    // MARK: Model breakdown

    private var modelBreakdown: [(String, Int)] {
        var counts: [String: Int] = [:]
        for id in store.selection {
            let model = store.rows[id]?.model ?? "— (pre-v1 / unrecorded)"
            counts[model, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    @ViewBuilder
    private var modelBreakdownSection: some View {
        EyebrowLabel("Models used")
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(modelBreakdown, id: \.0) { pair in
                HStack {
                    Text(pair.0)
                        .font(AppFont.monoLabel)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text("\(pair.1)")
                        .font(AppFont.body)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatTimestamp(_ ts: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

// MARK: - Inspector content

/// The concrete, per-selection inspector body. Every `@State` here is tied
/// to a specific `assetId` via the parent's `.id(id)` modifier.
private struct InspectorContent: View {
    @Bindable var store: LibraryStore
    let assetId: String

    // Hero preview
    @State private var heroImage: NSImage? = nil
    @State private var heroLoadFailed: Bool = false

    // Description editor (draft state)
    @State private var draftDescription: String = ""
    @State private var draftTags: [String] = []
    @State private var isEditing: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil
    @State private var newTagText: String = ""

    // Lazy PhotoKit metadata
    @State private var asset: PHAsset? = nil
    @State private var albums: [String] = []

    // Copy-to-clipboard confirmation flash
    @State private var descriptionCopied: Bool = false
    @State private var tagsCopied: Bool = false

    // Collapsible section state (session-local, not persisted)
    @State private var isDeveloperOpen: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                heroSection
                SurfaceCard { identitySection }
                SurfaceCard { descriptionSection }
                SurfaceCard { tagsSection }
                SurfaceCard { provenanceSection }
                SurfaceCard { visionSection }
                SurfaceCard { developerSection }
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: assetId) {
            await loadContent()
        }
        // React to the keyboard-triggered edit signal from the grid (E or
        // Return key). The grid sets `wantsEdit = true`; we flip into edit
        // mode for the current description and reset the flag so the
        // same keystroke doesn't re-trigger on the next render.
        .onChange(of: store.wantsEdit) { _, newValue in
            guard newValue else { return }
            let current = store.rows[assetId]?.description ?? ""
            beginEditing(with: current)
            store.wantsEdit = false
        }
    }

    // MARK: - Hero preview

    @ViewBuilder
    private var heroSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .fill(AppColor.surfaceSunken)
                .aspectRatio(3/2, contentMode: .fit)

            if let img = heroImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
            } else if heroLoadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    // MARK: - Identity section

    @ViewBuilder
    private var identitySection: some View {
        sectionHeader("Identity", systemImage: "info.circle")
        VStack(alignment: .leading, spacing: 6) {
            if let asset {
                identityRow("File", value: filename(asset) ?? "—")
                identityRow("Created", value: formatDate(asset.creationDate))
                if let modified = asset.modificationDate,
                   modified != asset.creationDate {
                    identityRow("Modified", value: formatDate(modified))
                }
                identityRow("Dimensions", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                identityRow("Type", value: PhotoLibrary.mediaTypeLabel(asset.mediaType))
                if asset.isFavorite {
                    identityRow("Favorite", value: "★")
                }
                if let loc = asset.location {
                    identityRow(
                        "Location",
                        value: String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude)
                    )
                }
                if !albums.isEmpty {
                    identityRow("Albums", value: albums.joined(separator: ", "))
                }
            } else {
                Text("PhotoKit asset not available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The full PHAsset localIdentifier is hidden under a disclosure
            // because it's long and rarely useful outside debugging.
            identityRow("Asset ID", value: assetId, monospaced: true)
        }
    }

    @ViewBuilder
    private func identityRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(label)
                .font(AppFont.label)
                .foregroundStyle(AppColor.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(monospaced ? AppFont.monoCaption : AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Description editor

    @ViewBuilder
    private var descriptionSection: some View {
        sectionHeader(
            "Description",
            systemImage: "text.alignleft",
            trailing: descriptionHeaderTrailing
        )

        if let row = store.rows[assetId], row.description != nil || isEditing {
            descriptionEditor(row: row)
        } else if store.rows[assetId] == nil {
            Text("Untouched — no description yet. Run a batch to generate one.")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
        } else {
            // Row exists but description is empty (pending / failed / cleared)
            Text("No description yet.")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
            Button("Start editing") {
                beginEditing(with: "")
            }
            .buttonStyle(.link)
            .font(AppFont.label)
        }
    }

    @ViewBuilder
    private func descriptionEditor(row: AssetQueue.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                TextEditor(text: $draftDescription)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                HStack {
                    Button("Save", action: saveEdit)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || !isDescriptionDirty)
                    Button("Revert", role: .cancel, action: revertEdit)
                        .disabled(isSaving)
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
                if let err = saveError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else {
                Text(row.description ?? "")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") {
                    beginEditing(with: row.description ?? "")
                }
                .buttonStyle(.link)
                .font(AppFont.label)
            }
        }
    }

    private var descriptionHeaderTrailing: AnyView? {
        if isDescriptionDirty {
            return AnyView(Circle().fill(Color.accentColor).frame(width: 7, height: 7))
        }
        guard let desc = store.rows[assetId]?.description, !desc.isEmpty, !isEditing else { return nil }
        return AnyView(
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(desc, forType: .string)
                withAnimation { descriptionCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation { descriptionCopied = false }
                }
            } label: {
                Image(systemName: descriptionCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(descriptionCopied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(descriptionCopied ? "Copied!" : "Copy description to clipboard")
        )
    }

    // MARK: - Tags section

    @ViewBuilder
    private var tagsSection: some View {
        let activeTags = isEditing ? draftTags : (store.rows[assetId]?.tags ?? [])

        sectionHeader("Tags", systemImage: "tag", trailing: tagsHeaderTrailing(tags: activeTags))

        if activeTags.isEmpty {
            Text("No tags.")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
        } else {
            ChipFlowLayout(spacing: 8, runSpacing: 8) {
                ForEach(activeTags, id: \.self) { tag in
                    inspectorTagChip(tag: tag)
                }
            }
        }

        if isEditing {
            HStack(spacing: 6) {
                TextField("Add tag…", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addDraftTag() }
                Button("Add", action: addDraftTag)
                    .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func tagsHeaderTrailing(tags: [String]) -> AnyView? {
        guard !tags.isEmpty else { return nil }
        return AnyView(
            HStack(spacing: Spacing.sm) {
                Text("\(tags.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if !isEditing {
                    Button {
                        let joined = tags.sorted().joined(separator: ", ")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(joined, forType: .string)
                        withAnimation { tagsCopied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { tagsCopied = false }
                        }
                    } label: {
                        Image(systemName: tagsCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(tagsCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tagsCopied ? "Copied!" : "Copy tags to clipboard")
                }
            }
        )
    }

    // MARK: - Processing provenance

    @ViewBuilder
    private var provenanceSection: some View {
        let tint: Color = {
            switch store.rows[assetId]?.status {
            case "done":                    return AppColor.statusDone
            case "pending", "in_progress":  return AppColor.statusPending
            case "failed":                  return AppColor.statusFailed
            default:                        return .accentColor
            }
        }()
        sectionHeader("Processing", systemImage: "cpu", tint: tint)

        if let row = store.rows[assetId] {
            VStack(alignment: .leading, spacing: 6) {
                identityRow("Status", value: row.status.capitalized)
                if let model = row.model {
                    identityRow("Model", value: model, monospaced: true)
                } else if row.status == "done" {
                    identityRow("Model", value: "— (pre-v1 row, not recorded)")
                }
                if let sentinel = row.sentinel {
                    identityRow("Sentinel", value: sentinel, monospaced: true)
                }
                if let ts = row.processedAt {
                    identityRow("Ran at", value: formatTimestamp(ts))
                }
                if let total = row.totalMs {
                    identityRow("Total", value: formatMs(total))
                    TimingBar(visionMs: row.visionMs ?? 0, ollamaMs: row.ollamaMs ?? 0, totalMs: total)
                        .frame(height: 14)
                        .padding(.top, Spacing.xs)
                } else if let ollama = row.ollamaMs {
                    identityRow("Ollama", value: formatMs(ollama))
                }
                if row.attempts > 1 {
                    identityRow("Attempts", value: "\(row.attempts)")
                }
                if let ed = row.updatedAt, row.processedAt != ed, ed != row.processedAt ?? 0 {
                    identityRow("Edited at", value: formatTimestamp(ed))
                }
                if let err = row.error {
                    identityRow("Error", value: err, monospaced: true)
                        .foregroundStyle(.red)
                }
            }
        } else {
            Text("No processing record for this asset.")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Vision section

    @ViewBuilder
    private var visionSection: some View {
        sectionHeader("Vision", systemImage: "eye")

        if let findings = decodedVisionFindings {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if findings.classifications.isEmpty
                    && findings.animals.isEmpty
                    && findings.faces.isEmpty
                    && findings.ocrText.isEmpty {
                    Text("Vision pre-pass ran but found nothing structured.")
                        .font(AppFont.body)
                        .foregroundStyle(.secondary)
                }

                if !findings.classifications.isEmpty {
                    EyebrowLabel("Classifications")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(findings.classifications.prefix(5), id: \.identifier) { label in
                            HStack(spacing: Spacing.sm) {
                                Text(label.identifier)
                                    .font(AppFont.label)
                                    .foregroundStyle(AppColor.textPrimary)
                                    .frame(width: 140, alignment: .leading)
                                    .lineLimit(1)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(AppColor.surfaceSunken)
                                        Capsule()
                                            .fill(Color.accentColor.opacity(0.85))
                                            .frame(width: geo.size.width * CGFloat(max(0, min(1, label.confidence))))
                                    }
                                }
                                .frame(height: 10)
                                Text(String(format: "%.2f", label.confidence))
                                    .font(AppFont.monoCaption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }

                if !findings.animals.isEmpty {
                    identityRow("Animals", value: "\(findings.animals.count) (\(findings.animals.map(\.label).joined(separator: ", ")))")
                }
                if !findings.faces.isEmpty {
                    identityRow("Faces", value: "\(findings.faces.count)")
                }
                if !findings.ocrText.isEmpty {
                    EyebrowLabel("OCR")
                    Text(findings.ocrText.joined(separator: " · "))
                        .font(AppFont.monoCaption)
                        .foregroundStyle(AppColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppColor.surfaceSunken)
                        )
                }
                identityRow("Vision time", value: String(format: "%.0f ms", findings.elapsedSeconds * 1000))
            }
        } else if store.rows[assetId]?.status == "done" {
            Text("No Vision data recorded for this row (pre-v1 done row).")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
        } else {
            Text("Vision pre-pass runs when the photo is processed.")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Developer section

    @ViewBuilder
    private var developerSection: some View {
        DisclosureGroup(isExpanded: $isDeveloperOpen) {
            if let row = store.rows[assetId] {
                VStack(alignment: .leading, spacing: 4) {
                    devRow("id", row.id)
                    devRow("status", row.status)
                    devRow("attempts", String(row.attempts))
                    devRow("error", row.error ?? "nil")
                    devRow("processed_at", row.processedAt.map(String.init) ?? "nil")
                    devRow("model", row.model ?? "nil")
                    devRow("sentinel", row.sentinel ?? "nil")
                    devRow("vision_ms", row.visionMs.map(String.init) ?? "nil")
                    devRow("ollama_ms", row.ollamaMs.map(String.init) ?? "nil")
                    devRow("total_ms", row.totalMs.map(String.init) ?? "nil")
                    devRow("updated_at", row.updatedAt.map(String.init) ?? "nil")
                    devRow("tags_count", String(row.tags.count))
                    devRow("vision_json_bytes", row.visionJSON.map { String($0.utf8.count) } ?? "nil")

                    if let desc = row.description {
                        Text("description payload (what's in Photos.app)")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, Spacing.xs)
                        Text(Pipeline.formatDescription(
                            description: desc,
                            tags: row.tags,
                            sentinel: row.sentinel ?? store.currentSentinel
                        ))
                        .font(AppFont.monoCaption)
                        .foregroundStyle(AppColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppColor.surfaceSunken)
                        )
                    }
                }
            } else {
                Text("No queue row.").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                    .frame(width: 22, alignment: .center)
                Text("Developer")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func devRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(k)
                .font(AppFont.monoCaption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(v)
                .font(AppFont.monoCaption)
                .foregroundStyle(AppColor.textPrimary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Section header helper

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String, tint: Color = .accentColor, trailing: AnyView? = nil) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .center)
            Text(title)
                .font(AppFont.sectionTitle)
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Load

    private func loadContent() async {
        // Reset per-selection state (the parent already gave us a fresh view
        // via `.id(assetId)`, but explicit is clearer).
        self.heroImage = nil
        self.heroLoadFailed = false
        self.isEditing = false
        self.saveError = nil
        self.albums = []

        // Fetch the PHAsset once for this selection. It's used by the hero
        // loader, identity section, and album lookup.
        guard let fetched = PhotoLibrary.fetch(id: assetId) else {
            self.asset = nil
            self.heroLoadFailed = true
            return
        }
        self.asset = fetched

        async let heroTask: Void = loadHero(asset: fetched)
        async let albumTask: Void = loadAlbums(asset: fetched)
        _ = await (heroTask, albumTask)
    }

    private func loadHero(asset: PHAsset) async {
        let target = CGSize(width: 720, height: 720)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        // `.highQualityFormat` delivers a single callback per Apple's docs.
        // A flag guards against any edge case where iCloud assets deliver
        // a degraded placeholder first — we resume on the non-degraded
        // payload only.
        let img: NSImage? = await withCheckedContinuation { cont in
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFit, options: opts
            ) { img, info in
                if didResume { return }
                // If we got a degraded placeholder and the request will still
                // deliver a better one, skip this callback.
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded {
                    return
                }
                didResume = true
                cont.resume(returning: img)
            }
        }
        if img == nil { self.heroLoadFailed = true }
        self.heroImage = img
    }

    private func loadAlbums(asset: PHAsset) async {
        // PHAssetCollection.fetchAssetCollectionsContaining is synchronous
        // and main-thread-safe. Wrapping in async keeps the call site
        // uniform with `loadHero`.
        let result = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var titles: [String] = []
        result.enumerateObjects { col, _, _ in
            if let t = col.localizedTitle, !t.isEmpty {
                titles.append(t)
            }
        }
        self.albums = titles.sorted()
    }

    // MARK: - Editing

    private var isDescriptionDirty: Bool {
        guard isEditing else { return false }
        let stored = store.rows[assetId]?.description ?? ""
        if draftDescription != stored { return true }
        let storedTags = store.rows[assetId]?.tags ?? []
        if draftTags != storedTags { return true }
        return false
    }

    private func beginEditing(with text: String) {
        draftDescription = text
        draftTags = store.rows[assetId]?.tags ?? []
        saveError = nil
        newTagText = ""
        isEditing = true
    }

    private func revertEdit() {
        draftDescription = store.rows[assetId]?.description ?? ""
        draftTags = store.rows[assetId]?.tags ?? []
        saveError = nil
        newTagText = ""
        isEditing = false
    }

    private func saveEdit() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await store.saveDescription(
                    id: assetId,
                    description: draftDescription,
                    tags: draftTags
                )
                isEditing = false
            } catch {
                saveError = "\(error)"
            }
        }
    }

    /// Build one tag chip for the inspector's tags section. Extracted as a
    /// separate helper because the SwiftUI type-checker was timing out on
    /// the inlined form with the multi-closure `TagChipView` initializer
    /// and the ternary `onRemove:`.
    @ViewBuilder
    private func inspectorTagChip(tag: String) -> some View {
        let isActive = store.isTagActive(tag)
        let removeInEdit: (() -> Void)? = isEditing
            ? { draftTags.removeAll { $0 == tag } }
            : nil
        TagChipView(
            tag: tag,
            isActiveFilter: isActive,
            canEdit: isEditing,
            onToggle: { store.toggleTagFilter(tag) },
            onViewOnly: { store.setSoleTagFilter(tag) },
            onRemoveFromFilters: isActive ? { store.removeTagFilter(tag) } : nil,
            onRemoveFromPhoto: removeInEdit
        )
    }

    private func addDraftTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !draftTags.contains(trimmed) else {
            newTagText = ""
            return
        }
        draftTags.append(trimmed)
        newTagText = ""
    }

    // MARK: - Vision decode

    private var decodedVisionFindings: VisionFindings? {
        guard let json = store.rows[assetId]?.visionJSON,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(VisionFindings.self, from: data)
    }

    // MARK: - Formatters

    private func filename(_ asset: PHAsset) -> String? {
        // `filename` is undocumented KVC but widely used and stable. Used by
        // Apple's own sample code and AppKit photo picker internals.
        asset.value(forKey: "filename") as? String
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func formatTimestamp(_ ts: Int64) -> String {
        formatDate(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func formatMs(_ ms: Int) -> String {
        if ms >= 1000 {
            return String(format: "%.2f s", Double(ms) / 1000.0)
        }
        return "\(ms) ms"
    }
}

// MARK: - Common tag chip (multi-selection summary)

/// Lightweight tag pill used by `MultiSelectionSummary.commonTagsSection`.
/// Tap toggles the tag in the active filter set. Doesn't carry the full
/// edit/remove machinery of `TagChipView` because the multi-selection
/// summary is read-only — it's a digest, not an editor.
private struct CommonTagChip: View {
    let tag: String
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(tag)
                .font(AppFont.label)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(AppColor.tagTint(for: tag).opacity(0.78))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tag chip

/// Pill-shaped tag label with left-click-to-toggle, right-click context menu,
/// and (in edit mode) an inline × to remove the tag from the photo. The
/// toggle semantics match the sidebar Popular Tags row so both surfaces
/// behave the same: click once to add to `activeTagFilters`, click again
/// to take it back out.
private struct TagChipView: View {
    let tag: String
    let isActiveFilter: Bool
    let canEdit: Bool
    let onToggle: () -> Void
    let onViewOnly: () -> Void
    let onRemoveFromFilters: (() -> Void)?
    let onRemoveFromPhoto: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(tag)
                .font(AppFont.label)
                .foregroundStyle(.white)
                .lineLimit(1)
            if canEdit, let onRemoveFromPhoto {
                Button {
                    onRemoveFromPhoto()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(AppColor.tagTint(for: tag).opacity(isActiveFilter ? 1.00 : 0.78))
        )
        .overlay(
            Capsule()
                .stroke(isActiveFilter ? Color.white.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture { onToggle() }
        .contextMenu {
            Button("View only photos with this tag", action: onViewOnly)
            if isActiveFilter, let onRemoveFromFilters {
                Button("Remove from active filters", action: onRemoveFromFilters)
            } else {
                Button("Add to active filters", action: onToggle)
            }
            Divider()
            Button("Copy tag") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tag, forType: .string)
            }
            if canEdit, let onRemoveFromPhoto {
                Divider()
                Button("Remove from this photo", role: .destructive, action: onRemoveFromPhoto)
            }
        }
    }
}

// MARK: - Timing bar

/// Tiny inline bar visualizing vision/ollama/rest split of total processing
/// time. Makes the architecture visible at a glance in the inspector.
private struct TimingBar: View {
    let visionMs: Int
    let ollamaMs: Int
    let totalMs: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                Rectangle()
                    .fill(Color.blue.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(visionMs) / CGFloat(max(1, totalMs)))
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(ollamaMs) / CGFloat(max(1, totalMs)))
                Rectangle()
                    .fill(Color.gray.opacity(0.4))
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

// MARK: - Flow layout

/// Simple wrap-to-width flow layout. Used by the tag chip list to let
/// chips flow to the next line when they overflow the inspector width.
/// macOS 14+ has the `Layout` protocol — no third-party dep needed.
///
/// `private` so it doesn't collide with the legacy `ChipFlowLayout` in
/// `PhotoPreview.swift` (old UI). Phase 6 deletes the old UI and this
/// one can then be promoted to file-internal if anything else needs it.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var runSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                maxRowWidth = max(maxRowWidth, x - spacing)
                y += rowHeight + runSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        maxRowWidth = max(maxRowWidth, x - spacing)
        let total = y + rowHeight
        return CGSize(
            width: maxWidth.isFinite ? maxWidth : maxRowWidth,
            height: total
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + runSpacing
                x = 0
                rowHeight = 0
            }
            sv.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
