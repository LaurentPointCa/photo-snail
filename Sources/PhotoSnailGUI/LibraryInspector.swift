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
            if let id = store.selection {
                InspectorContent(store: store, assetId: id)
                    .id(id)
            } else {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "photo",
                    description: Text("Select a photo in the grid to inspect it.")
                )
            }
        }
        .navigationTitle("Inspector")
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

    // Collapsible section state (session-local, not persisted)
    @State private var isDeveloperOpen: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroSection
                identitySection
                Divider()
                descriptionSection
                Divider()
                tagsSection
                Divider()
                provenanceSection
                Divider()
                visionSection
                Divider()
                developerSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: assetId) {
            await loadContent()
        }
    }

    // MARK: - Hero preview

    @ViewBuilder
    private var heroSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.12))
                .aspectRatio(4/3, contentMode: .fit)

            if let img = heroImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if heroLoadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
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
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
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
            trailing: isDescriptionDirty ? AnyView(Circle().fill(Color.accentColor).frame(width: 7, height: 7)) : nil
        )

        if let row = store.rows[assetId], row.description != nil || isEditing {
            descriptionEditor(row: row)
        } else if store.rows[assetId] == nil {
            Text("Untouched — no description yet. Run a batch to generate one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // Row exists but description is empty (pending / failed / cleared)
            Text("No description yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Start editing") {
                beginEditing(with: "")
            }
            .buttonStyle(.link)
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
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") {
                    beginEditing(with: row.description ?? "")
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - Tags section

    @ViewBuilder
    private var tagsSection: some View {
        let activeTags = isEditing ? draftTags : (store.rows[assetId]?.tags ?? [])

        sectionHeader("Tags", systemImage: "tag", trailing: activeTags.isEmpty ? nil : AnyView(
            Text("\(activeTags.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        ))

        if activeTags.isEmpty {
            Text("No tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ChipFlowLayout(spacing: 6, runSpacing: 6) {
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

    // MARK: - Processing provenance

    @ViewBuilder
    private var provenanceSection: some View {
        sectionHeader("Processing", systemImage: "cpu")

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
                        .frame(height: 10)
                        .padding(.top, 2)
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Vision section

    @ViewBuilder
    private var visionSection: some View {
        sectionHeader("Vision", systemImage: "eye")

        if let findings = decodedVisionFindings {
            VStack(alignment: .leading, spacing: 8) {
                if findings.classifications.isEmpty
                    && findings.animals.isEmpty
                    && findings.faces.isEmpty
                    && findings.ocrText.isEmpty {
                    Text("Vision pre-pass ran but found nothing structured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !findings.classifications.isEmpty {
                    Text("Classifications")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(findings.classifications.prefix(5), id: \.identifier) { label in
                        HStack(spacing: 6) {
                            Text(label.identifier)
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.gray.opacity(0.15))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.accentColor.opacity(0.6))
                                        .frame(width: geo.size.width * CGFloat(max(0, min(1, label.confidence))))
                                }
                            }
                            .frame(height: 6)
                            Text(String(format: "%.2f", label.confidence))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
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
                    Text("OCR")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(findings.ocrText.joined(separator: " · "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                identityRow("Vision time", value: String(format: "%.0f ms", findings.elapsedSeconds * 1000))
            }
        } else if store.rows[assetId]?.status == "done" {
            Text("No Vision data recorded for this row (pre-v1 done row).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Vision pre-pass runs when the photo is processed.")
                .font(.caption)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Text(Pipeline.formatDescription(
                            description: desc,
                            tags: row.tags,
                            sentinel: row.sentinel ?? store.currentSentinel
                        ))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(4)
                    }
                }
            } else {
                Text("No queue row.").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label("Developer", systemImage: "curlybraces")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func devRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    // MARK: - Section header helper

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String, trailing: AnyView? = nil) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
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
        HStack(spacing: 4) {
            Text(tag)
                .font(.caption)
                .lineLimit(1)
            if canEdit, let onRemoveFromPhoto {
                Button {
                    onRemoveFromPhoto()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isActiveFilter ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15))
        )
        .overlay(
            Capsule()
                .stroke(isActiveFilter ? Color.accentColor : Color.clear, lineWidth: 1)
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
