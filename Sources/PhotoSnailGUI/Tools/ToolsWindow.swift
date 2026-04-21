import SwiftUI
import AppKit
import PhotoSnailCore

/// Selector for which tool a `ToolWindow` is running. Drives the header
/// copy, the presence of the Apply toggle, and which `ToolsEngine` entry
/// point the Run button invokes. One enum covers all three tools because
/// their surface area is 95% identical (header + run button + results
/// list + context menu) — just the column layout and the engine call
/// change per mode.
enum ToolMode: String, CaseIterable, Identifiable, Sendable {
    case scanMulti
    case cleanMulti
    case scanPreserved

    var id: String { rawValue }

    var windowId: String {
        switch self {
        case .scanMulti:     return "tool-scan-multi"
        case .cleanMulti:    return "tool-clean-multi"
        case .scanPreserved: return "tool-scan-preserved"
        }
    }

    var title: String {
        switch self {
        case .scanMulti:     return "Scan: Multi-segment descriptions"
        case .cleanMulti:    return "Clean: Multi-segment descriptions"
        case .scanPreserved: return "Scan: Preserved original descriptions"
        }
    }

    var explanation: String {
        switch self {
        case .scanMulti:
            return """
            Finds processed assets whose description contains more than one \
            PhotoSnail payload (≥2 `ai:…-v<N>` sentinels or ≥2 `\\n\\n---\\n\\n` \
            separators). These are left over from pre-v0.1.5 reprocessing that \
            appended rather than replaced. Read-only — no changes are made.
            """
        case .cleanMulti:
            return """
            Collapses each multi-segment description down to a single PhotoSnail \
            payload (the most recent one) while preserving any user-authored text \
            before the first or after the last sentinel segment. Dry-run by default \
            — enable "Apply" to write the cleaned descriptions back to Photos.app.
            """
        case .scanPreserved:
            return """
            Finds assets where a user-authored description existed before PhotoSnail \
            touched them and was preserved across the `\\n\\n---\\n\\n` separator. \
            Handy for auditing which assets have custom metadata the user wrote \
            (Stable Diffusion prompts, manual notes, existing captions). Read-only.
            """
        }
    }

    var hasApplyToggle: Bool {
        self == .cleanMulti
    }
}

// MARK: - Per-window state

/// One instance per open tool window. Holds the scan task, progress
/// counters, and accumulated findings. `@Observable` so the view
/// re-renders as findings stream in.
@Observable
@MainActor
final class ToolState {
    var isRunning: Bool = false
    var isApplying: Bool = false

    /// Progress counters — mirrored straight from `ToolsEngine.Progress`
    /// ticks so the header can render `"scanned/total · found"` without
    /// computing anything.
    var scanned: Int = 0
    var total: Int = 0
    var errors: Int = 0

    /// Three parallel arrays, one per tool. Only the one matching the
    /// window's `mode` is populated; keeping them separate means the view
    /// doesn't have to downcast an `Any`-typed finding list.
    var multiFindings: [ToolsEngine.MultiFinding] = []
    var preservedFindings: [ToolsEngine.PreservedFinding] = []
    var cleanCandidates: [ToolsEngine.CleanCandidate] = []

    /// User-facing status line under the run button. Used for end-of-run
    /// summaries ("Done — 14 candidates") and error surface.
    var statusMessage: String = ""

    /// Apply toggle for the clean tool. Ignored by the others.
    var applyChanges: Bool = false

    /// One row's write outcome in the clean tool's apply phase. `error`
    /// is nil on success. Plain struct (not `Result<Void, Error>`) because
    /// `String` doesn't conform to `Error` and wrapping errors in a custom
    /// type adds zero value for a pure UI status render.
    struct WriteResult: Hashable, Sendable {
        let success: Bool
        let error: String?
    }

    /// Write-phase results, keyed by asset id. Used to color candidate
    /// rows after an apply run: green ✓ or red ✕.
    var writeResults: [String: WriteResult] = [:]

    /// Active scan/apply task. Kept so the Stop button can cancel.
    var runTask: Task<Void, Never>?

    func reset() {
        scanned = 0
        total = 0
        errors = 0
        multiFindings.removeAll()
        preservedFindings.removeAll()
        cleanCandidates.removeAll()
        writeResults.removeAll()
        statusMessage = ""
    }
}

// MARK: - Root window view

struct ToolWindow: View {
    let mode: ToolMode
    @State private var state = ToolState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            explanation
            if mode.hasApplyToggle {
                applyToggle
            }
            runControls
            Divider()
            resultsList
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            Text(mode.title)
                .font(.title2).bold()
            Spacer()
        }
    }

    private var headerIcon: String {
        switch mode {
        case .scanMulti:     return "doc.text.magnifyingglass"
        case .cleanMulti:    return "wand.and.stars"
        case .scanPreserved: return "person.text.rectangle"
        }
    }

    private var explanation: some View {
        Text(mode.explanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var applyToggle: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { state.applyChanges },
                set: { state.applyChanges = $0 }
            )) {
                Text("Apply changes — actually rewrite descriptions in Photos.app")
                    .font(.body)
            }
            .toggleStyle(.checkbox)
            .disabled(state.isRunning)
            if state.applyChanges {
                Text("⚠ Will modify your library")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Run controls

    private var runControls: some View {
        HStack(spacing: 10) {
            if state.isRunning {
                Button("Stop") {
                    state.runTask?.cancel()
                }
                .buttonStyle(.bordered)
                ProgressView()
                    .controlSize(.small)
                if state.total > 0 {
                    Text("\(state.scanned)/\(state.total) · found \(foundCount)\(state.errors > 0 ? " · errors \(state.errors)" : "")")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(primaryButtonTitle) {
                    startRun()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .scanMulti:     return foundCount == 0 ? "Run scan" : "Re-run scan"
        case .cleanMulti:    return state.applyChanges ? "Scan + apply" : "Scan (dry run)"
        case .scanPreserved: return foundCount == 0 ? "Run scan" : "Re-run scan"
        }
    }

    private var foundCount: Int {
        switch mode {
        case .scanMulti:     return state.multiFindings.count
        case .cleanMulti:    return state.cleanCandidates.count
        case .scanPreserved: return state.preservedFindings.count
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        switch mode {
        case .scanMulti:     MultiResultsList(state: state)
        case .cleanMulti:    CleanResultsList(state: state)
        case .scanPreserved: PreservedResultsList(state: state)
        }
    }

    // MARK: - Run dispatch

    private func startRun() {
        state.reset()
        state.isRunning = true
        state.statusMessage = "Opening queue…"

        let selected = mode
        let apply = state.applyChanges

        state.runTask = Task { @MainActor in
            defer {
                state.isRunning = false
                state.isApplying = false
            }

            // 1. Open queue + fetch done ids. One-time cost per run.
            let queue: AssetQueue
            let ids: [String]
            do {
                queue = try await ToolsEngine.openQueue()
                ids = try await ToolsEngine.fetchDoneIds(queue: queue)
            } catch {
                state.statusMessage = "Failed to open queue: \(error)"
                return
            }
            state.total = ids.count
            state.statusMessage = "Scanning \(ids.count) assets…"

            // 2. Dispatch to the right engine call.
            switch selected {
            case .scanMulti:
                await ToolsEngine.scanMulti(
                    ids: ids,
                    onProgress: { progress in
                        state.scanned = progress.scanned
                        state.errors = progress.errors
                    },
                    onFinding: { f in
                        state.multiFindings.append(f)
                    }
                )
                if Task.isCancelled {
                    state.statusMessage = "Stopped at \(state.scanned)/\(state.total) · found \(foundCount)."
                } else {
                    state.statusMessage = foundCount == 0
                        ? "Done — no multi-segment descriptions found."
                        : "Done — \(foundCount) asset\(foundCount == 1 ? "" : "s") with multi-segment descriptions."
                }

            case .cleanMulti:
                await ToolsEngine.scanCleanCandidates(
                    ids: ids,
                    onProgress: { progress in
                        state.scanned = progress.scanned
                        state.errors = progress.errors
                    },
                    onFinding: { c in
                        state.cleanCandidates.append(c)
                    }
                )
                if Task.isCancelled {
                    state.statusMessage = "Stopped at \(state.scanned)/\(state.total) · found \(foundCount) candidate(s)."
                    return
                }
                if foundCount == 0 {
                    state.statusMessage = "Done — nothing to clean."
                    return
                }
                if !apply {
                    state.statusMessage = "Dry run — \(foundCount) candidate(s). Enable Apply to rewrite."
                    return
                }
                // Apply phase
                state.isApplying = true
                state.statusMessage = "Writing \(foundCount) cleaned descriptions…"
                let candidates = state.cleanCandidates
                await ToolsEngine.applyCleanCandidates(candidates) { id, success, err in
                    state.writeResults[id] = ToolState.WriteResult(success: success, error: err)
                }
                let wrote = state.writeResults.values.filter { $0.success }.count
                let failed = state.writeResults.count - wrote
                state.statusMessage = failed == 0
                    ? "Done — wrote \(wrote) cleaned description\(wrote == 1 ? "" : "s")."
                    : "Done — wrote \(wrote) · \(failed) failed (see red rows below)."

            case .scanPreserved:
                await ToolsEngine.scanPreserved(
                    ids: ids,
                    onProgress: { progress in
                        state.scanned = progress.scanned
                        state.errors = progress.errors
                    },
                    onFinding: { f in
                        state.preservedFindings.append(f)
                    }
                )
                if Task.isCancelled {
                    state.statusMessage = "Stopped at \(state.scanned)/\(state.total) · found \(foundCount)."
                } else {
                    state.statusMessage = foundCount == 0
                        ? "Done — no preserved user descriptions found."
                        : "Done — \(foundCount) asset\(foundCount == 1 ? "" : "s") with preserved user text."
                }
            }
        }
    }
}

// MARK: - Results lists (one per mode)

/// Shared context menu factory. Each row has this on right-click so the
/// "Show in PhotoSnail library" verb is defined in exactly one place.
private func revealMenu(for id: String) -> some View {
    Group {
        Button {
            ToolsRouter.shared.pendingReveal = id
            ToolsRouter.shared.activateLibraryWindow()
        } label: {
            Label("Show in PhotoSnail library", systemImage: "photo.on.rectangle.angled")
        }
        Divider()
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
        } label: {
            Label("Copy asset id", systemImage: "doc.on.doc")
        }
    }
}

/// Per-row "Show in library" button. The context menu alone isn't reliable
/// on rows that contain selectable text — AppKit shows the text field's
/// own right-click menu instead of SwiftUI's `.contextMenu`. An explicit
/// button keeps the verb reachable regardless of where the pointer lands.
private struct RevealInLibraryButton: View {
    let id: String

    var body: some View {
        Button {
            ToolsRouter.shared.pendingReveal = id
            ToolsRouter.shared.activateLibraryWindow()
        } label: {
            Label("Show in library", systemImage: "photo.on.rectangle.angled")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Open this asset in the PhotoSnail library window")
    }
}

/// Results list for `scanMulti`. Tabular: uuid · sentinels · seps · len ·
/// preview. Monospaced columns so the counts align at a glance.
private struct MultiResultsList: View {
    let state: ToolState

    var body: some View {
        if state.multiFindings.isEmpty {
            emptyState
        } else {
            List {
                ForEach(state.multiFindings) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(f.id.prefix(8)))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text("sents \(f.sentinels)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                        Text("seps \(f.separators)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                        Text("\(f.length)B")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(f.preview)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RevealInLibraryButton(id: f.id)
                    }
                    .contextMenu { revealMenu(for: f.id) }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            state.isRunning ? "Scanning…" : "No results yet",
            systemImage: state.isRunning ? "hourglass" : "doc.text.magnifyingglass",
            description: Text(state.isRunning
                ? "Findings will stream in here as the scan progresses."
                : "Click \"Run scan\" to find assets with multi-segment descriptions.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Results list for `scanPreserved`. Renders the full user prefix below
/// the header row because reading what the user wrote is the whole point.
private struct PreservedResultsList: View {
    let state: ToolState

    var body: some View {
        if state.preservedFindings.isEmpty {
            emptyState
        } else {
            List {
                ForEach(state.preservedFindings) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(String(f.id.prefix(8)))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("total \(f.descriptionLength)B · prefix \(f.userPrefix.count) chars")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            RevealInLibraryButton(id: f.id)
                        }
                        Text(f.userPrefix)
                            .font(.system(.body, design: .default))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                    .contextMenu { revealMenu(for: f.id) }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            state.isRunning ? "Scanning…" : "No results yet",
            systemImage: state.isRunning ? "hourglass" : "person.text.rectangle",
            description: Text(state.isRunning
                ? "Findings will stream in here as the scan progresses."
                : "Click \"Run scan\" to find assets where user text was preserved before our payload.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Results list for `cleanMulti`. Each row shows before/after byte counts
/// and a write-status indicator when Apply has run. Color-coded based on
/// `state.writeResults[id]`: green ✓ for success, red ✕ for failure,
/// neutral when no write attempted (dry run).
private struct CleanResultsList: View {
    let state: ToolState

    var body: some View {
        if state.cleanCandidates.isEmpty {
            emptyState
        } else {
            List {
                ForEach(state.cleanCandidates) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        writeStatusGlyph(for: c.id)
                            .frame(width: 18, alignment: .center)
                        Text(String(c.id.prefix(8)))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text("\(c.before.count)B → \(c.after.count)B")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 140, alignment: .leading)
                        Text("−\(c.byteDelta)B")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .frame(width: 70, alignment: .trailing)
                        Text(previewOf(c.after))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RevealInLibraryButton(id: c.id)
                    }
                    .contextMenu { revealMenu(for: c.id) }
                }
            }
            .listStyle(.plain)
        }
    }

    private func previewOf(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: "⏎")
        return one.count > 80 ? String(one.prefix(80)) + "…" : one
    }

    @ViewBuilder
    private func writeStatusGlyph(for id: String) -> some View {
        if let r = state.writeResults[id] {
            if r.success {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(r.error ?? "write failed")
            }
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            state.isRunning ? "Scanning…" : "No results yet",
            systemImage: state.isRunning ? "hourglass" : "wand.and.stars",
            description: Text(state.isRunning
                ? "Candidates will stream in here as the scan progresses."
                : "Click the button to scan. Enable Apply first if you want to write.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
