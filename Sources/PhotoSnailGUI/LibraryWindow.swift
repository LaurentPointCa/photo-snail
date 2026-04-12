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
    @State private var showLegend = false

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
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
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
                    // Sort order menu — acts on the grid. Placed first so
                    // the eye reaches it before the view-style picker.
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            ForEach(LibraryStore.SortOrder.allCases) { option in
                                Button {
                                    store.sortOrder = option
                                } label: {
                                    // Checkmark on the currently-selected
                                    // option so the menu doubles as state.
                                    if store.sortOrder == option {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                        .help("Sort order")
                    }

                    // Thumbnail size — three-way segmented picker bound
                    // directly to the store's preset enum. ⌘1/2/3 hit the
                    // same code path via the grid's key handler.
                    ToolbarItem(placement: .automatic) {
                        Picker("Thumbnail size", selection: Bindable(store).thumbnailSize) {
                            Image(systemName: "square.grid.4x3.fill")
                                .tag(LibraryStore.ThumbnailSize.small)
                            Image(systemName: "square.grid.3x3.fill")
                                .tag(LibraryStore.ThumbnailSize.medium)
                            Image(systemName: "square.grid.2x2.fill")
                                .tag(LibraryStore.ThumbnailSize.large)
                        }
                        .pickerStyle(.segmented)
                        .help("Thumbnail size (⌘1 / ⌘2 / ⌘3)")
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            showLegend = true
                        } label: {
                            Label("Legend", systemImage: "questionmark.circle")
                        }
                        .help("Keyboard shortcuts + status badge legend")
                        .popover(isPresented: $showLegend, arrowEdge: .top) {
                            LegendPopover()
                        }
                    }
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

    /// Pixel-art wordmark combining the snail sprite with the "PHOTO
    /// SNAIL" pixel-font text. Generated by `tools/make-icon.swift` at
    /// 132 × 64 source pixels and copied into the bundle by
    /// `bundle-gui.sh`. Resolved once at class scope so the lookup
    /// doesn't fire on every render. Falls through to `nil` if the
    /// asset is missing (e.g. dev build without bundle step), in which
    /// case the header renders a plain text fallback.
    private static let logoWordmark: NSImage? = {
        if let url = Bundle.main.url(forResource: "LogoWordmark", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()

    var body: some View {
        List {
            // Brand header — pixel-art wordmark at the top of the sidebar.
            Section {
                Group {
                    if let wordmark = Self.logoWordmark {
                        Image(nsImage: wordmark)
                            .resizable()
                            // High-quality downscale — the source asset
                            // is generated at ~800 px wide, well above
                            // the display size, so SwiftUI always
                            // downsamples rather than upsamples.
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 72)
                    } else {
                        Text("photo snail")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.md)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                filterRow(.all, label: "All", count: store.totalCount, systemImage: "photo.stack", tint: .accentColor)
                filterRow(.tagged, label: "Tagged", count: store.taggedCount, systemImage: "checkmark.seal.fill", tint: AppColor.statusDone)
                filterRow(.untouched, label: "Untouched", count: store.untouchedCount, systemImage: "circle.dashed", tint: AppColor.statusUntouched)
                filterRow(.pending, label: "Pending", count: store.pendingCount, systemImage: "hourglass", tint: AppColor.statusPending)
                filterRow(.failed, label: "Failed", count: store.failedCount, systemImage: "exclamationmark.triangle.fill", tint: AppColor.statusFailed)
            } header: {
                EyebrowLabel("Library")
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
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                } header: {
                    HStack {
                        EyebrowLabel("Active Filters")
                        Spacer()
                        Text("\(store.activeTagFilters.count)")
                            .font(AppFont.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Popular tags in the current display set. Hidden when there's
            // nothing interesting to show — avoids a lonely empty section.
            if !store.popularTags.isEmpty {
                Section {
                    ForEach(store.popularTags) { freq in
                        PopularTagRow(
                            frequency: freq,
                            isActive: store.isTagActive(freq.tag)
                        ) {
                            store.toggleTagFilter(freq.tag)
                        }
                    }
                } header: {
                    EyebrowLabel("Popular Tags")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("photo-snail")
    }

    @ViewBuilder
    private func filterRow(_ f: LibraryStore.Filter, label: String, count: Int, systemImage: String, tint: Color) -> some View {
        Button {
            store.setFilter(f)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22, alignment: .center)
                Text(label)
                    .font(AppFont.label)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text("\(count)")
                    .font(AppFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            Group {
                if store.filter == f {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                }
            }
        )
    }
}

/// One row in the sidebar's Active Filters section: the tag name in a
/// compact pill + a tap-target × button to remove it.
private struct ActiveFilterRow: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .imageScale(.small)
                    .foregroundStyle(.white.opacity(0.9))
                Text(tag)
                    .font(AppFont.label)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(AppColor.tagTint(for: tag).opacity(0.85))
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
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
            HStack(spacing: Spacing.md) {
                Circle()
                    .fill(AppColor.tagTint(for: frequency.tag))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle().stroke(Color.white.opacity(isActive ? 0.7 : 0.0), lineWidth: 1)
                    )
                Text(frequency.tag)
                    .font(AppFont.label)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? AppColor.textPrimary : AppColor.textSecondary)
                Spacer()
                Text("\(frequency.count)")
                    .font(AppFont.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(AppColor.tagTint(for: frequency.tag).opacity(isActive ? 0.95 : 0.55))
                    )
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            Group {
                if isActive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                }
            }
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

    /// Derived from `store.thumbnailSize`. Kept as a computed property so
    /// changing the store's preset automatically propagates to the grid.
    private var thumbnailSize: CGFloat { store.thumbnailSize.points }
    private let gridSpacing: CGFloat = 10

    @State private var showingKeyboardClearConfirm: Bool = false
    @State private var showingKeyboardReprocessConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Bulk action bar — always present so the grid doesn't
            // reflow when the selection changes. Buttons are disabled
            // when nothing is selected.
            BulkActionBar(store: store)
            gridBody
        }
        .navigationTitle(navigationTitleText)
        .navigationSubtitle(subtitle)
        .searchable(
            text: Bindable(store).searchText,
            placement: .toolbar,
            prompt: "Search descriptions and tags"
        )
        // Keyboard shortcuts. The grid is the focusable host; disabling the
        // focus effect keeps the whole pane from glowing blue on every click.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
        // Progress sheet for long bulk ops (Clear description). Bound to
        // `bulkProgress` via Bindable so the sheet dismisses automatically
        // when the store sets it back to nil.
        .sheet(item: Bindable(store).bulkProgress) { _ in
            BulkProgressSheet(store: store)
        }
        // Full-screen photo preview triggered by Space on a single selection.
        .sheet(isPresented: Bindable(store).wantsPreview) {
            FullscreenPreviewSheet(store: store)
        }
        // Keyboard-triggered bulk confirmations. These live here rather than
        // on BulkActionBar because the key handler is on the grid.
        .confirmationDialog(
            "Clear descriptions from \(store.selection.count) photo\(store.selection.count == 1 ? "" : "s")?",
            isPresented: $showingKeyboardClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear descriptions", role: .destructive) {
                Task { await store.clearSelectionDescriptions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the photo-snail-written description from Photos.app and resets each queue row to pending. Original photos are not modified. This cannot be undone.")
        }
        .confirmationDialog(
            "Re-process \(store.selection.count) photo\(store.selection.count == 1 ? "" : "s")?",
            isPresented: $showingKeyboardReprocessConfirm,
            titleVisibility: .visible
        ) {
            Button("Re-process") {
                Task { await store.requeueSelection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Queued photos will be processed on the next Start.")
        }
    }

    /// Keyboard dispatch for the grid. Factored out of `.onKeyPress`
    /// because the switch got big enough that inlining it hurt type-check
    /// time. Returns `.handled` when we consumed the press, `.ignored`
    /// otherwise so SwiftUI can route it further (e.g. to `.searchable`).
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Esc → clear selection
        if press.key == .escape {
            if !store.selection.isEmpty {
                store.clearSelection()
                return .handled
            }
            return .ignored
        }
        // ⌘A → select all visible
        if press.modifiers.contains(.command) && press.characters == "a" {
            store.selectAllInView()
            return .handled
        }
        // ⌘1 / ⌘2 / ⌘3 → thumbnail size presets
        if press.modifiers.contains(.command) {
            switch press.characters {
            case "1": store.thumbnailSize = .small;  return .handled
            case "2": store.thumbnailSize = .medium; return .handled
            case "3": store.thumbnailSize = .large;  return .handled
            default:  break
            }
        }
        // Arrow navigation — left/right through displayOrder. Up/down is
        // deferred because LazyVGrid.adaptive has no stable column count.
        if press.key == .leftArrow {
            store.moveSelectionPrev()
            return .handled
        }
        if press.key == .rightArrow {
            store.moveSelectionNext()
            return .handled
        }
        // Space → full-screen preview of the single selection
        if press.characters == " " && press.modifiers.isEmpty {
            if store.singleSelection != nil {
                store.wantsPreview = true
                return .handled
            }
            return .ignored
        }
        // E (or Return) → enter edit mode for the single selection's
        // description. The inspector observes `wantsEdit` and flips into
        // edit mode on the next render.
        if press.characters == "e" && press.modifiers.isEmpty {
            if store.singleSelection != nil {
                store.wantsEdit = true
                return .handled
            }
            return .ignored
        }
        if press.key == .return && press.modifiers.isEmpty {
            if store.singleSelection != nil {
                store.wantsEdit = true
                return .handled
            }
            return .ignored
        }
        // R → bulk re-process (with confirmation when >10)
        if press.characters == "r" && press.modifiers.isEmpty {
            guard !store.selection.isEmpty else { return .ignored }
            if store.selection.count > 10 {
                showingKeyboardReprocessConfirm = true
            } else {
                Task { await store.requeueSelection() }
            }
            return .handled
        }
        // Delete / Backspace → bulk clear descriptions (always confirmed)
        if press.key == .delete || press.key == .deleteForward {
            guard !store.selection.isEmpty else { return .ignored }
            showingKeyboardClearConfirm = true
            return .handled
        }
        return .ignored
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
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
                            .id(id)
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
                // Scroll the grid to follow the current single selection
                // when it changes. `anchor: .center` keeps the active
                // photo near the middle of the viewport so arrow-key
                // navigation feels continuous even on long scroll lists.
                .onChange(of: store.singleSelection) { _, new in
                    guard store.scrollOnSelectionChange, let id = new else { return }
                    store.scrollOnSelectionChange = false
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                // Follow-current-processing: when the toggle in the runner
                // dock is on, every engine advance scrolls the grid to the
                // photo the worker is currently on. Firing via onChange of
                // the engine's currentPhotoID means no extra polling.
                .onChange(of: store.engineCurrentPhotoID) { _, new in
                    guard store.followCurrentProcessing, let id = new else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
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
    @State private var isHovering: Bool = false

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
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: 3
                )
                .frame(width: size, height: size)

            StatusBadge(row: row)
                .padding(6)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        // Soft accent halo around the selected cell — gives single-photo
        // selections enough visual punch to stand out against the dark
        // grid background. The stroke alone reads as subtle when only one
        // cell carries it.
        .shadow(
            color: isSelected ? Color.accentColor.opacity(0.55) : .clear,
            radius: isSelected ? 6 : 0,
            x: 0,
            y: 0
        )
        // Subtle lift + soft shadow on hover. Makes the grid feel alive
        // without being distracting; 120 ms ease is short enough that
        // fast mouse sweeps don't leave trailing shadow artifacts.
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .shadow(
            color: .black.opacity(isHovering ? 0.32 : 0),
            radius: isHovering ? 8 : 0,
            x: 0,
            y: isHovering ? 3 : 0
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
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

        // Pixel target = display points × backing scale factor, with a 2×
        // floor for standard 2× Retina. On a 3× display (recent MacBook
        // Pros) this asks PhotoKit for 3× resolution so the thumbnail
        // stays crisp at its rendered size.
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2.0, 2.0)
        let target = CGSize(width: size * scale, height: size * scale)

        // .highQualityFormat + .exact resize produces a properly filtered
        // thumbnail at the requested pixel size — not the tiny cached
        // preview that .fastFormat returns. The cost is an extra render
        // per cell the first time it appears (PhotoKit caches the result
        // internally, so later scrolls are fast).
        //
        // Network access is left disabled: for iCloud-only assets we'd
        // rather show a grey placeholder than pay cloud latency on every
        // grid scroll. The hover preview + full-screen preview do enable
        // network because they're per-photo intentional peeks.
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        // .highQualityFormat is single-delivery in theory, but iCloud
        // assets can still yield a degraded callback first. Same pattern
        // as HoverPhotoPreview: resume on the non-degraded frame only.
        let loaded: NSImage? = await withCheckedContinuation { cont in
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: options
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
                        .fill(AppColor.statusDone)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.40), radius: 2, x: 0, y: 1)
                )
            case "pending", "in_progress":
                return AnyView(
                    Circle()
                        .strokeBorder(AppColor.statusPending, lineWidth: 2.5)
                        .background(Circle().fill(Color.black.opacity(0.30)))
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.40), radius: 2, x: 0, y: 1)
                )
            case "failed":
                return AnyView(
                    Circle()
                        .fill(AppColor.statusFailed)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Text("!")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.40), radius: 2, x: 0, y: 1)
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

    private var hasSelection: Bool { !store.selection.isEmpty }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Text(hasSelection ? "\(store.selection.count) selected" : "No selection")
                .font(AppFont.bodyEmphasized)
                .monospacedDigit()
                .foregroundStyle(hasSelection ? AppColor.textPrimary : AppColor.textSecondary)

            // Transient status message from the most recent bulk op.
            if let msg = store.bulkStatusMessage {
                Text(msg)
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                Task { await store.requeueSelection() }
            } label: {
                Label("Re-process", systemImage: "arrow.clockwise")
            }
            .help("Re-process — push these photos back into the pending queue")
            .disabled(!hasSelection)

            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Label("Clear", systemImage: "eraser")
            }
            .help("Clear description — remove photo-snail descriptions from Photos.app")
            .disabled(!hasSelection)

            Button {
                runExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export JSON — save every selected row to a file")
            .disabled(!hasSelection)

            Divider()
                .frame(height: 16)

            Button {
                store.clearSelection()
            } label: {
                Label("Deselect", systemImage: "xmark.circle")
            }
            .help("Deselect all")
            .disabled(!hasSelection)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(AppFont.label)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColor.borderSubtle)
                .frame(height: 1)
        }
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

// MARK: - Legend popover

/// Toolbar-attached popover that documents the status badges and the
/// keyboard shortcuts. Discoverability aid — the rest of the app tries
/// to be obvious, this is where the non-obvious bits live.
struct LegendPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                legendHeader("Status badges", systemImage: "circle.hexagongrid.fill")
                badgeRow(color: AppColor.statusDone, label: "Tagged", description: "Photo has a description in Photos.app.")
                badgeRow(color: AppColor.statusPending, label: "Pending", description: "Queued for processing. Live ring while in-progress.", ringed: true)
                badgeRow(color: AppColor.statusFailed, label: "Failed", description: "Processing failed. Retry via bulk Re-process.")
                badgeRow(color: AppColor.statusUntouched, label: "Untouched", description: "Not yet enumerated into the queue.")
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                legendHeader("Keyboard shortcuts", systemImage: "keyboard")
                keyRow("⌘F", "Search descriptions + tags")
                keyRow("←  →", "Previous / next photo")
                keyRow("Space", "Full-screen preview")
                keyRow("Return  E", "Edit description")
                keyRow("⌘⏎", "Save edit")
                keyRow("⌘A", "Select all visible")
                keyRow("⌘1 / 2 / 3", "Small / medium / large thumbs")
                keyRow("⌘-click", "Toggle selection")
                keyRow("⇧-click", "Range-select")
                keyRow("Esc", "Clear selection / close preview")
                keyRow("R", "Re-process selection")
                keyRow("⌫", "Clear descriptions for selection")
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
    }

    @ViewBuilder
    private func legendHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, alignment: .center)
            Text(title)
                .font(AppFont.sectionTitle)
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
        }
        .padding(.bottom, Spacing.xs)
    }

    @ViewBuilder
    private func badgeRow(color: Color, label: String, description: String, ringed: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ZStack {
                if ringed {
                    Circle().strokeBorder(color, lineWidth: 2.5)
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: ringed ? 0 : 1.5))
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(AppFont.bodyEmphasized)
                    .foregroundStyle(AppColor.textPrimary)
                Text(description)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ key: String, _ action: String) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Text(key)
                .font(AppFont.monoLabel)
                .foregroundStyle(AppColor.textPrimary)
                .frame(width: 96, alignment: .leading)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AppColor.surfaceSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
                )
            Text(action)
                .font(AppFont.label)
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
        }
    }
}

// MARK: - Fullscreen preview sheet

/// Large photo preview presented when the user hits Space with exactly
/// one selection. Dismissed by Esc, by the X button, or by clicking
/// outside the image. Reads the single selection from the store, loads
/// a high-quality version via `PHImageManager`, and sizes itself to fit
/// within the current window.
///
/// Kept deliberately simple: it's not QuickLook and it's not a sheet
/// with navigation chrome. Just a dim backdrop, a big image, and a
/// close affordance. The runner-dock hover popover already covers the
/// "small peek" case; this is the "take it all in" case.
struct FullscreenPreviewSheet: View {
    @Bindable var store: LibraryStore

    @State private var image: NSImage? = nil
    @State private var failed: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                .onTapGesture {
                    store.wantsPreview = false
                }

            Group {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(24)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text("Preview unavailable")
                    }
                    .foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                store.wantsPreview = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(16)
            .keyboardShortcut(.cancelAction)
        }
        // ~85% of main screen; modal sheet already has some chrome.
        .frame(
            minWidth: 600, idealWidth: idealSize.width, maxWidth: .infinity,
            minHeight: 400, idealHeight: idealSize.height, maxHeight: .infinity
        )
        .task(id: store.singleSelection) {
            await loadImage()
        }
    }

    private var idealSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        return CGSize(width: screen.width * 0.85, height: screen.height * 0.85)
    }

    private func loadImage() async {
        image = nil
        failed = false
        guard let id = store.singleSelection,
              let asset = PhotoLibrary.fetch(id: id) else {
            failed = true
            return
        }
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1600, height: 1200)
        let target = CGSize(width: screen.width * 2, height: screen.height * 2)
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

    /// User preference for whether the dock is collapsed to its compact
    /// form (stats + ETA + primary button only) or expanded to its full
    /// form (cards + stats + follow toggle + primary button). Persisted
    /// per-user via @AppStorage so a long-running batch session doesn't
    /// re-expand on every relaunch.
    @AppStorage("photo-snail.runnerDockCollapsed") private var isCollapsed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Compact header row: just the collapse/expand chevron, pinned
            // to the top-right. Always visible so the user can flip the
            // dock from compact to expanded without hunting for a control.
            HStack {
                if isCollapsed {
                    EyebrowLabel(engine.state == .running ? "Running" : "Batch")
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(AppColor.surfaceSunken)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand runner panel" : "Collapse runner panel")
            }

            if !isCollapsed {
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
            }

            // Session stats + progress bar — always visible. The whole
            // point of the collapsed mode is to keep this small block plus
            // the primary button, freeing the rest of the sidebar for
            // popular tags during a long-running batch.
            if engine.totalCount > 0 {
                statsBlock
            }

            if !isCollapsed {
                // Follow-current-processing toggle. Off by default — the user
                // is usually browsing somewhere else while a batch runs. When
                // on, LibraryGrid's onChange(engine.currentPhotoID) scrolls
                // the grid to the in-flight photo every advance.
                Toggle(isOn: Bindable(store).followCurrentProcessing) {
                    Text("Follow processing in grid")
                        .font(AppFont.label)
                }
                .toggleStyle(.switch)
                .controlSize(.regular)
                .help("Auto-scroll the grid to the currently-processing photo")
            }

            // Primary action — always visible.
            primaryButton
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceHighlighted)
        .overlay(alignment: .top) {
            // Hairline separator instead of a full Divider — reads as
            // "the runner dock starts here" without the heavy default
            // List divider tone.
            Rectangle()
                .fill(AppColor.borderSubtle)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var statsBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("\(engine.doneCount)")
                    .font(AppFont.display)
                    .monospacedDigit()
                    .foregroundStyle(AppColor.textPrimary)
                Text("of \(engine.totalCount)")
                    .font(AppFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if !engine.etaString.isEmpty && engine.etaString != "--" {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .imageScale(.small)
                        Text("ETA \(engine.etaString)")
                            .font(AppFont.caption)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            DockProgressBar(progress: progressFraction)
                .frame(height: 6)
                .padding(.top, 2)
        }
    }

    private var progressFraction: Double {
        guard engine.totalCount > 0 else { return 0 }
        return Double(engine.doneCount) / Double(engine.totalCount)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch engine.state {
        case .idle, .finished:
            Button {
                Task { await engine.start() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(AppFont.bodyEmphasized)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .enumerating:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(engine.statusMessage)
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        case .running:
            Button {
                engine.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .font(AppFont.bodyEmphasized)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .paused:
            Button {
                engine.resume()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(AppFont.bodyEmphasized)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

/// Custom progress bar for the runner dock — chunkier and rounder than
/// the system `ProgressView(.linear)`, with an accent gradient fill so it
/// reads as "the focal progress indicator" rather than just a thin rule.
private struct DockProgressBar: View {
    let progress: Double  // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.opacity(0.80)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress))))
            }
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
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            EyebrowLabel(title)

            HStack(alignment: .top, spacing: Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.thumbnail)
                        .fill(AppColor.surfaceSunken)
                        .frame(width: 84, height: 84)
                    if let cg = thumbnail {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
                    }
                    RoundedRectangle(cornerRadius: Radius.thumbnail)
                        .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
                        .frame(width: 84, height: 84)
                    if isLive {
                        RoundedRectangle(cornerRadius: Radius.thumbnail)
                            .stroke(Color.accentColor.opacity(0.85), lineWidth: 3)
                            .frame(width: 84, height: 84)
                            .scaleEffect(1 + 0.06 * pulsePhase)
                            .opacity(1 - 0.4 * pulsePhase)
                    }
                }
                // Hover-to-peek is scoped to the thumbnail only — we don't
                // want the caption area triggering the popover because it's
                // wide, close to other controls, and changes size when a
                // new photo arrives.
                .onHover { hovering in
                    hoverTask?.cancel()
                    if hovering {
                        // Delay before showing the popover so casual
                        // mouse-overs don't trigger it.
                        hoverTask = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            if !Task.isCancelled {
                                isHovering = true
                            }
                        }
                    } else {
                        // Small delay lets the mouse travel from the card
                        // edge to the popover area without triggering a
                        // dismiss-then-re-show flicker.
                        hoverTask = Task {
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
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(3)
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
