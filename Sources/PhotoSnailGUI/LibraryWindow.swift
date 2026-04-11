import SwiftUI
import Photos
import PhotoSnailCore

// MARK: - Top-level window

/// Three-column library browser root. Phase 2 skeleton: sidebar filters,
/// thumbnail grid, placeholder inspector. Phases 3–7 layer functionality on
/// top without changing the enclosing structure.
struct LibraryWindow: View {
    @State private var store = LibraryStore()

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
                } content: {
                    LibraryGrid(store: store)
                        .navigationSplitViewColumnWidth(min: 500, ideal: 700)
                } detail: {
                    LibraryInspector(store: store)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
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
            // Active-filter strip: shown only when a compound filter (tag
            // filter today; multi-tag/search in Phase 4) is in effect. Gives
            // the user a visible "why is the grid smaller than expected"
            // answer plus a one-click clear.
            if let tag = store.activeTagFilter {
                activeFilterStrip(tag: tag)
                Divider()
            }

            gridBody
        }
        .navigationTitle(navigationTitleText)
        .navigationSubtitle("\(store.displayOrder.count) of \(store.totalCount)")
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
                            isSelected: store.selection == id,
                            size: thumbnailSize
                        )
                        .onTapGesture {
                            store.selection = id
                        }
                    }
                }
                .padding(gridSpacing)
            }
        }
    }

    @ViewBuilder
    private func activeFilterStrip(tag: String) -> some View {
        HStack(spacing: 8) {
            Text("Filtered by tag")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(tag)
                    .font(.caption)
                Button {
                    store.setTagFilter(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.18))
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
