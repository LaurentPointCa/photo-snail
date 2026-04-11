import SwiftUI
import Photos
import PhotoSnailCore

// MARK: - Top-level window

/// Three-column library browser root. Phase 2 skeleton: sidebar filters,
/// thumbnail grid, placeholder inspector. Phases 3–7 layer functionality on
/// top without changing the enclosing structure.
struct LibraryWindow: View {
    @State private var store = LibraryStore()
    @State private var showSettings = false

    var body: some View {
        Group {
            if let err = store.loadError {
                ContentUnavailableView(
                    "Can't open library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            } else {
                NavigationSplitView {
                    LibrarySidebar(store: store)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                        .safeAreaInset(edge: .bottom) {
                            // Pinned runner dock — visible whenever the engine
                            // exists (post-load). Matches the priority of "the
                            // current + last completed must always be visible"
                            // from the Phase 0 plan.
                            if let engine = store.engine {
                                RunnerDock(engine: engine, store: store)
                            }
                        }
                } content: {
                    LibraryGrid(store: store)
                        .navigationSplitViewColumnWidth(min: 500, ideal: 700)
                } detail: {
                    LibraryInspector(store: store)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
                }
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("Model · sentinel · Ollama connection")
                        .disabled(store.engine == nil)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    if let engine = store.engine {
                        SettingsSheet(engine: engine, isPresented: $showSettings)
                    }
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .task {
            await store.load()
        }
    }
}

// MARK: - Sidebar

/// Filter list + row counts. Phase 2 uses a plain `List` with buttons rather
/// than `List(selection:)` because the latter needs `List` to own the
/// identity of the selection state, and I want it explicitly in `LibraryStore`.
struct LibrarySidebar: View {
    @Bindable var store: LibraryStore

    var body: some View {
        List {
            Section("Library") {
                filterRow(.all, label: "All", count: store.totalCount, systemImage: "photo.stack")
                filterRow(.tagged, label: "Tagged", count: store.taggedCount, systemImage: "checkmark.seal")
                filterRow(.untouched, label: "Untouched", count: store.untouchedCount, systemImage: "circle.dashed")
                filterRow(.pending, label: "Pending", count: store.pendingCount, systemImage: "hourglass")
                filterRow(.failed, label: "Failed", count: store.failedCount, systemImage: "exclamationmark.triangle")
            }

            // Active compound filters — only rendered when there's something
            // to show, so the sidebar stays clean at rest.
            if !store.activeTagFilters.isEmpty {
                Section {
                    ForEach(store.activeTagFiltersOrdered, id: \.self) { tag in
                        ActiveFilterRow(tag: tag) {
                            store.removeTagFilter(tag)
                        }
                    }
                    Button("Clear all") {
                        store.clearTagFilters()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Text("Active Filters")
                        Spacer()
                        Text("\(store.activeTagFilters.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            // Popular tags in the current display set. Hidden when there's
            // nothing interesting to show — avoids a lonely empty section.
            if !store.popularTags.isEmpty {
                Section("Popular Tags") {
                    ForEach(store.popularTags) { freq in
                        PopularTagRow(
                            frequency: freq,
                            isActive: store.isTagActive(freq.tag)
                        ) {
                            store.toggleTagFilter(freq.tag)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("photo-snail")
    }

    @ViewBuilder
    private func filterRow(_ f: LibraryStore.Filter, label: String, count: Int, systemImage: String) -> some View {
        Button {
            store.setFilter(f)
        } label: {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            store.filter == f ? Color.accentColor.opacity(0.18) : Color.clear
        )
    }
}

/// One row in the sidebar's Active Filters section: the tag name in a
/// compact pill + a tap-target × button to remove it.
private struct ActiveFilterRow: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag.fill")
                .imageScale(.small)
                .foregroundStyle(Color.accentColor)
            Text(tag)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One row in the sidebar's Popular Tags section: tag name + count. Tap
/// toggles the tag's membership in `activeTagFilters`. The active state
/// is indicated by a check glyph plus an accent highlight.
private struct PopularTagRow: View {
    let frequency: LibraryStore.TagFrequency
    let isActive: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: isActive ? "checkmark.circle.fill" : "number")
                    .imageScale(.small)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(frequency.tag)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(frequency.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isActive ? Color.accentColor.opacity(0.12) : Color.clear
        )
    }
}

// MARK: - Grid

/// Thumbnail grid bound to `LibraryStore.displayOrder`. Phase 2 uses a
/// `LazyVGrid` with per-cell `PHImageManager` requests (one request per cell,
/// cancelled on disappear). Phase 7 can replace this with `PHCachingImageManager`
/// if scroll perf is a problem on very large libraries.
struct LibraryGrid: View {
    @Bindable var store: LibraryStore

    private let thumbnailSize: CGFloat = 140
    private let gridSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            // Bulk action bar — only appears when something is selected.
            // Hosted outside the ScrollView so it stays pinned when the
            // grid scrolls.
            if !store.selection.isEmpty {
                BulkActionBar(store: store)
                Divider()
            }
            gridBody
        }
        .navigationTitle(navigationTitleText)
        .navigationSubtitle(subtitle)
        .searchable(
            text: Bindable(store).searchText,
            placement: .toolbar,
            prompt: "Search descriptions and tags"
        )
        // Keyboard shortcuts for selection — Esc clears, ⌘A selects all
        // visible. Needs a focusable host and we disable the focus ring
        // so the whole pane doesn't glow blue on every click.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            if press.key == .escape {
                store.clearSelection()
                return .handled
            }
            if press.modifiers.contains(.command) && press.characters == "a" {
                store.selectAllInView()
                return .handled
            }
            return .ignored
        }
        // Progress sheet for long bulk ops (Clear description). Bound to
        // `bulkProgress` via Bindable so the sheet dismisses automatically
        // when the store sets it back to nil.
        .sheet(item: Bindable(store).bulkProgress) { _ in
            BulkProgressSheet(store: store)
        }
    }

    private var subtitle: String {
        let shown = store.displayOrder.count
        let total = store.totalCount
        if shown == total { return "\(total)" }
        return "\(shown) of \(total)"
    }

    @ViewBuilder
    private var gridBody: some View {
        if store.isLoading && store.displayOrder.isEmpty {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.displayOrder.isEmpty {
            ContentUnavailableView(
                emptyStateTitle,
                systemImage: emptyStateIcon,
                description: Text(emptyStateDescription)
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 60), spacing: gridSpacing)],
                    spacing: gridSpacing
                ) {
                    ForEach(store.displayOrder, id: \.self) { id in
                        ThumbnailCell(
                            id: id,
                            row: store.rows[id],
                            isSelected: store.selection.contains(id),
                            size: thumbnailSize
                        )
                        .onTapGesture {
                            // Read modifier keys at click time. ⌘-click
                            // toggles, ⇧-click range-extends, plain click
                            // replaces the selection. Matches Finder /
                            // Photos.app conventions.
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.command) {
                                store.toggleInSelection(id)
                            } else if mods.contains(.shift) {
                                store.extendSelection(to: id)
                            } else {
                                store.select(id)
                            }
                        }
                    }
                }
                .padding(gridSpacing)
            }
        }
    }

    // MARK: Dynamic chrome

    private var navigationTitleText: String {
        switch store.filter {
        case .all:       return "All"
        case .tagged:    return "Tagged"
        case .untouched: return "Untouched"
        case .pending:   return "Pending"
        case .failed:    return "Failed"
        }
    }

    private var emptyStateTitle: String {
        switch store.filter {
        case .all:       return "Library is empty"
        case .tagged:    return "Nothing tagged yet"
        case .untouched: return "Everything is enumerated"
        case .pending:   return "No pending work"
        case .failed:    return "No failures"
        }
    }

    private var emptyStateIcon: String {
        switch store.filter {
        case .failed: return "checkmark.seal"
        default:      return "photo.on.rectangle"
        }
    }

    private var emptyStateDescription: String {
        switch store.filter {
        case .all:       return "No images were found in your Photos library."
        case .tagged:    return "Run a batch to start generating descriptions."
        case .untouched: return "Every photo has a queue row. Nothing to discover."
        case .pending:   return "The queue has no pending work to process."
        case .failed:    return "No asset has ended in the failed state."
        }
    }
}

// MARK: - Thumbnail cell

/// One grid cell: rounded thumbnail, status badge, selection border.
/// Phase 2 loads on `onAppear` and cancels the request on `onDisappear`.
/// SwiftUI recycles cells on scroll, so the in-cell `@State` image is lost
/// and the request re-fires — acceptable for a skeleton; Phase 7 will add a
/// store-level image cache if needed.
struct ThumbnailCell: View {
    let id: String
    let row: AssetQueue.Row?
    let isSelected: Bool
    let size: CGFloat

    @State private var image: NSImage? = nil
    @State private var loadTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.12))
                .frame(width: size, height: size)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
                .frame(width: size, height: size)

            StatusBadge(row: row)
                .padding(6)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onAppear {
            loadTask?.cancel()
            loadTask = Task { await loadThumbnail() }
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }

    private func loadThumbnail() async {
        guard image == nil else { return }
        guard let asset = PhotoLibrary.fetch(id: id) else { return }

        // Scale 2× for Retina. `.fastFormat` gives a single delivery (one
        // completion callback), which avoids the "continuation called twice"
        // trap from `.opportunistic`. Use `.highQualityFormat` later if the
        // fast thumbnails look muddy.
        let target = CGSize(width: size * 2, height: size * 2)
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let loaded: NSImage? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: options
            ) { img, _ in
                cont.resume(returning: img)
            }
        }

        if Task.isCancelled { return }
        self.image = loaded
    }
}

// MARK: - Status badge

/// Small filled-circle indicator in the top-right of a thumbnail.
/// - green dot = tagged (done, has a description)
/// - amber ring = pending / in-progress
/// - red dot = failed
/// - nothing = untouched (no queue row)
struct StatusBadge: View {
    let row: AssetQueue.Row?

    var body: some View {
        Group {
            guard let row else {
                return AnyView(EmptyView())
            }
            switch row.status {
            case "done":
                return AnyView(
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                )
            case "pending", "in_progress":
                return AnyView(
                    Circle()
                        .strokeBorder(Color.orange, lineWidth: 2)
                        .background(Circle().fill(Color.black.opacity(0.25)))
                        .frame(width: 12, height: 12)
                )
            case "failed":
                return AnyView(
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Text("!")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                )
            default:
                return AnyView(EmptyView())
            }
        }
    }
}

// Note: `LibraryInspector` lives in `LibraryInspector.swift` — it grew large
// enough to deserve its own file in Phase 3.

// MARK: - Bulk action bar

/// The toolbar that appears above the grid when the user has selected one
/// or more photos. Shows the count and four actions: Re-process, Clear,
/// Copy tags, Export, plus a Deselect.
///
/// Destructive operations (Clear) go through a confirmation alert. The
/// long-running Clear path flips `store.bulkProgress` which presents a
/// modal progress sheet higher up in the view hierarchy.
struct BulkActionBar: View {
    @Bindable var store: LibraryStore

    @State private var showingClearConfirm = false
    @State private var showingExportError: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text("\(store.selection.count) selected")
                .font(.callout.weight(.medium))

            // Transient status message from the most recent bulk op.
            // Non-intrusive — sits inline in the action bar and fades
            // when the user clicks anything else.
            if let msg = store.bulkStatusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Re-process — fast, no confirmation needed. Just a SQL-level
            // push back to pending; the actual run happens in the runner.
            Button {
                Task { await store.requeueSelection() }
            } label: {
                Label("Re-process", systemImage: "arrow.clockwise")
            }
            .help("Re-process — push these photos back into the pending queue")

            // Clear description — destructive, gated on confirmation.
            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Label("Clear description", systemImage: "eraser")
            }
            .help("Clear description — remove photo-snail descriptions from Photos.app")

            // Copy tags — instant, no confirmation.
            Button {
                store.copySelectionTagsToPasteboard()
            } label: {
                Label("Copy tags", systemImage: "doc.on.clipboard")
            }
            .help("Copy tags — union of all selected tags to the clipboard")

            // Export JSON — opens an NSSavePanel.
            Button {
                runExport()
            } label: {
                Label("Export JSON", systemImage: "square.and.arrow.up")
            }
            .help("Export JSON — save every selected row to a file")

            Divider()
                .frame(height: 16)

            Button {
                store.clearSelection()
            } label: {
                Label("Deselect", systemImage: "xmark.circle")
            }
            .help("Deselect all")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog(
            "Clear descriptions from \(store.selection.count) photo\(store.selection.count == 1 ? "" : "s")?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear descriptions", role: .destructive) {
                Task { await store.clearSelectionDescriptions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the photo-snail-written description from Photos.app and resets each queue row to pending. Original photos are not modified. This cannot be undone.")
        }
        .alert("Export failed", isPresented: Binding(
            get: { showingExportError != nil },
            set: { if !$0 { showingExportError = nil } }
        )) {
            Button("OK") { showingExportError = nil }
        } message: {
            Text(showingExportError ?? "")
        }
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "photo-snail-export.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.exportSelectionJSON(to: url)
            } catch {
                showingExportError = "\(error)"
            }
        }
    }
}

// MARK: - Runner dock

/// Compact runner pinned to the bottom of the sidebar. Surfaces the
/// "what is the batch doing right now" state so it's always visible
/// while the user browses or edits (priority #5 from the Phase 0
/// plan). Two thumbnail cards (last-completed on top, current below),
/// session stats, and a single Start/Pause/Resume button that adapts
/// to the engine's state machine.
struct RunnerDock: View {
    @Bindable var engine: ProcessingEngine
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            // Last-completed photo card (top). Stays on-screen between
            // photos so the user always has a concrete sense of what the
            // pipeline just did.
            DockPhotoCard(
                title: "Last completed",
                thumbnail: engine.completedThumbnail,
                caption: engine.completedDescription,
                assetId: engine.completedPhotoID
            )

            // Current photo card (bottom). Shows a pulsing accent ring
            // while the worker is running to match the Phase 0 mockup.
            DockPhotoCard(
                title: engine.state == .running ? "Processing" : "Idle",
                thumbnail: engine.currentThumbnail,
                caption: engine.statusMessage,
                isLive: engine.state == .running,
                assetId: engine.currentPhotoID
            )

            // Session stats + progress bar.
            if engine.totalCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(engine.doneCount) / \(engine.totalCount)")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        if !engine.etaString.isEmpty && engine.etaString != "--" {
                            Text("ETA \(engine.etaString)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(
                        value: Double(engine.doneCount),
                        total: Double(max(1, engine.totalCount))
                    )
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                }
            }

            // Primary action — changes label based on engine state.
            primaryButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch engine.state {
        case .idle, .finished:
            Button {
                Task { await engine.start() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        case .enumerating:
            HStack {
                ProgressView().controlSize(.small)
                Text(engine.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        case .running:
            Button {
                engine.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        case .paused:
            Button {
                engine.resume()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }
}

/// One thumbnail + caption line inside the runner dock. The optional
/// `isLive` flag draws a subtle accent ring that pulses slowly, used
/// to mark the currently-processing card while the worker is active.
///
/// `assetId` (when non-nil) enables a hover-triggered popover that
/// loads a larger version of the photo via `PHImageManager`. A short
/// dismiss delay keeps the popover from flickering when the mouse
/// grazes the card edge.
private struct DockPhotoCard: View {
    let title: String
    let thumbnail: CGImage?
    let caption: String
    var isLive: Bool = false
    var assetId: String? = nil

    @State private var pulsePhase: Double = 0
    @State private var isHovering: Bool = false
    @State private var dismissTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 56, height: 56)
                    if let cg = thumbnail {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if isLive {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(0.8), lineWidth: 2)
                            .frame(width: 56, height: 56)
                            .scaleEffect(1 + 0.06 * pulsePhase)
                            .opacity(1 - 0.4 * pulsePhase)
                    }
                }
                // Hover-to-peek is scoped to the thumbnail only — we don't
                // want the caption area triggering the popover because it's
                // wide, close to other controls, and changes size when a
                // new photo arrives.
                .onHover { hovering in
                    dismissTask?.cancel()
                    if hovering {
                        isHovering = true
                    } else {
                        // Small delay lets the mouse travel from the card
                        // edge to the popover area without triggering a
                        // dismiss-then-re-show flicker.
                        dismissTask = Task {
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            if !Task.isCancelled {
                                isHovering = false
                            }
                        }
                    }
                }
                .popover(
                    isPresented: Binding(
                        get: { isHovering && assetId != nil },
                        set: { isHovering = $0 }
                    ),
                    arrowEdge: .trailing
                ) {
                    if let id = assetId {
                        HoverPhotoPreview(assetId: id)
                    }
                }

                Text(caption.isEmpty ? "—" : caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if isLive {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulsePhase = 1
                }
            }
        }
        .onChange(of: isLive) { _, nowLive in
            if nowLive {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulsePhase = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    pulsePhase = 0
                }
            }
        }
    }
}

/// Popover content for the runner dock's hover-peek. Loads a larger
/// version of the asset from `PHImageManager` on first appear. Shows a
/// spinner while waiting, then the image. `.task(id: assetId)` cancels
/// and re-fetches cleanly if the id changes mid-hover.
///
/// The frame is sized to 75% of the main screen's shorter dimension so
/// the popover fills a substantial chunk of the display regardless of
/// whether the image is portrait or landscape, while still leaving room
/// for the popover arrow and enough margin to avoid spilling off-screen.
private struct HoverPhotoPreview: View {
    let assetId: String

    @State private var image: NSImage? = nil
    @State private var failed: Bool = false

    /// Screen-relative max dimension, computed once at view creation.
    /// On a 14" MacBook Pro (~1512 × 982 effective points) this is ~735;
    /// on a 27" 5K display it's ~1620.
    private let maxDimension: CGFloat = {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        return min(screen.width, screen.height) * 0.75
    }()

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxDimension, maxHeight: maxDimension)
                    .fixedSize()
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Preview unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: maxDimension * 0.6, height: maxDimension * 0.6)
            } else {
                // Reserve the expected footprint while loading so the popover
                // doesn't jump in size the moment the image arrives.
                ProgressView()
                    .controlSize(.large)
                    .frame(width: maxDimension * 0.6, height: maxDimension * 0.6)
            }
        }
        .padding(6)
        .task(id: assetId) {
            await loadLarge()
        }
    }

    private func loadLarge() async {
        image = nil
        failed = false
        guard let asset = PhotoLibrary.fetch(id: assetId) else {
            failed = true
            return
        }
        // Target pixel size: 2× the display cap, because PHImageManager's
        // `targetSize` is in pixels and Retina displays double the density.
        // `.highQualityFormat` still sometimes delivers a degraded frame
        // first on iCloud assets; guard against it so we don't flash a
        // blurry preview.
        let px = maxDimension * 2
        let target = CGSize(width: px, height: px)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        let loaded: NSImage? = await withCheckedContinuation { cont in
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFit, options: opts
            ) { img, info in
                if didResume { return }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                    return
                }
                didResume = true
                cont.resume(returning: img)
            }
        }
        if Task.isCancelled { return }
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }
}

// MARK: - Bulk progress sheet

/// Modal progress sheet shown during `clearSelectionDescriptions`. Observes
/// `store.bulkProgress` and offers a Cancel button that cooperatively
/// stops the loop after the current item finishes.
struct BulkProgressSheet: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let progress = store.bulkProgress {
                Text(progress.title)
                    .font(.headline)

                ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(progress.completed) / \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if !progress.failed.isEmpty {
                        Text("\(progress.failed.count) failed")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let currentId = progress.currentId {
                    Text(String(currentId.prefix(8)) + "…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        store.bulkProgress?.isCancelled = true
                    }
                    .disabled(progress.isCancelled)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
