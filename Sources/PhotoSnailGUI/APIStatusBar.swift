import SwiftUI
import AppKit
import Photos
import PhotoSnailCore
import PhotoSnailPhotos

// MARK: - Root bar

/// Window-wide bottom chrome strip. Left half: LLM provider pill + live
/// request tail (the "tail -f" over the provider's traffic). Right half:
/// small glanceable icons for the non-LLM runtime signals (Photos auth,
/// idle-sleep assertion, lock-watcher armed).
///
/// Pinned to the NavigationSplitView via `.safeAreaInset(edge: .bottom)`
/// in `LibraryWindow` so it spans all three columns. Height is kept
/// compact (~32 pt) so it reads as chrome, not content.
struct APIStatusBar: View {
    @Bindable var engine: ProcessingEngine

    var body: some View {
        HStack(spacing: Spacing.md) {
            ProviderStatusView(engine: engine)
                .layoutPriority(0)     // left half yields to right so health
                                       // icons are never pushed off-screen
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 14)

            SystemHealthView(engine: engine)
                .layoutPriority(1)
                .fixedSize()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

// MARK: - Provider status (left half)

private struct ProviderStatusView: View {
    let engine: ProcessingEngine
    private let loc = Localizer.shared

    var body: some View {
        let monitor = APIStatusMonitor.shared
        HStack(spacing: Spacing.sm) {
            Image(systemName: providerIcon)
                .foregroundStyle(.secondary)
                .help(connectionTooltip)

            StatusPill(state: monitor.connectionState)

            EventTailView(event: monitor.lastEvent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var providerIcon: String {
        switch engine.apiProvider {
        case .ollama: return "cpu"
        case .openaiCompatible: return "server.rack"
        }
    }

    private var connectionTooltip: String {
        switch engine.apiProvider {
        case .ollama:
            return "\(engine.apiProvider.displayName) · \(engine.connection.baseURL.absoluteString)"
        case .openaiCompatible:
            return "\(engine.apiProvider.displayName) · \(engine.openaiConnection.baseURL.absoluteString)"
        }
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let state: APIStatusMonitor.ConnectionState
    private let loc = Localizer.shared

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(background)
        )
        .overlay(
            Capsule().strokeBorder(AppColor.borderSubtle, lineWidth: 1)
        )
        .help(tooltip)
    }

    private var label: String {
        switch state {
        case .unknown: return loc.t("pill.unknown")
        case .connected: return loc.t("pill.connected")
        case .failed: return loc.t("pill.unreachable")
        }
    }

    private var tooltip: String {
        switch state {
        case .unknown: return loc.t("pill.unknown")
        case .connected(let provider): return "\(loc.t("pill.connected")) · \(provider)"
        case .failed(let reason): return "\(loc.t("pill.unreachable")): \(reason)"
        }
    }

    private var dotColor: Color {
        switch state {
        case .connected: return AppColor.statusDone
        case .failed: return AppColor.statusFailed
        case .unknown: return AppColor.statusUntouched
        }
    }

    private var textColor: Color {
        switch state {
        case .connected, .failed: return .primary
        case .unknown: return .secondary
        }
    }

    private var background: Color {
        switch state {
        case .connected: return AppColor.statusDone.opacity(0.14)
        case .failed: return AppColor.statusFailed.opacity(0.14)
        case .unknown: return AppColor.statusUntouched.opacity(0.10)
        }
    }
}

// MARK: - Event tail

/// Single-line "tail -f" of the provider's most recent request. In-flight
/// requests use a TimelineView to tick the elapsed-seconds counter every
/// second without re-running the rest of the hierarchy.
private struct EventTailView: View {
    let event: APIStatusMonitor.APIEvent?

    var body: some View {
        if let event {
            switch event.phase {
            case .inFlight(let startedAt):
                TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    tailLine(
                        glyph: "→",
                        body: formatBody(event: event, suffix: "\(elapsed)s"),
                        glyphTint: .secondary,
                        bodyTint: .secondary,
                        bold: false
                    )
                }
            case .completed(let duration):
                tailLine(
                    glyph: "✓",
                    body: formatBody(event: event, suffix: String(format: "%.1fs", duration)),
                    glyphTint: AppColor.statusDone,
                    bodyTint: AppColor.statusDone,
                    bold: true
                )
            case .failed(let duration, let reason):
                let trimmed = reason.split(separator: "\n").first.map(String.init) ?? reason
                tailLine(
                    glyph: "✕",
                    body: formatBody(
                        event: event,
                        suffix: String(format: "%.1fs · %@", duration, trimmed as NSString)
                    ),
                    glyphTint: AppColor.statusFailed,
                    bodyTint: AppColor.statusFailed,
                    bold: true
                )
            }
        } else {
            Text("—")
                .font(AppFont.monoCaption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Compose the tail text. Order: `[asset]` · call · model · suffix —
    /// asset prefix is first because that's the "which photo is this about"
    /// context the user asked to surface.
    private func formatBody(event: APIStatusMonitor.APIEvent, suffix: String) -> String {
        var parts: [String] = []
        if let asset = event.assetId, !asset.isEmpty {
            parts.append(String(asset.prefix(8)))
        }
        parts.append(event.call)
        if let model = event.model, !model.isEmpty { parts.append(model) }
        parts.append(suffix)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func tailLine(
        glyph: String,
        body: String,
        glyphTint: Color,
        bodyTint: Color,
        bold: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(glyph)
                .font(AppFont.monoCaption)
                .foregroundStyle(glyphTint)
            Text(body)
                .font(bold
                      ? .system(size: 12, weight: .semibold, design: .monospaced)
                      : AppFont.monoCaption)
                .foregroundStyle(bodyTint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - System health (right half)

private struct SystemHealthView: View {
    let engine: ProcessingEngine
    private let loc = Localizer.shared

    var body: some View {
        HStack(spacing: Spacing.md) {
            if UpdateChecker.shared.currentDisplayVersion != nil {
                UpdateVersionStrip(release: UpdateChecker.shared.availableRelease)
            }
            HealthIcon(
                symbol: "photo.on.rectangle.angled",
                active: photosAuthOK,
                tooltip: photosTooltip
            )
            HealthIcon(
                symbol: "lock.shield",
                active: engine.autoStartWhenLocked,
                tooltip: lockTooltip
            )
        }
    }

    private var photosAuthOK: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    private var photosTooltip: String {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return "\(loc.t("health.photos_tooltip")): \(PhotoLibrary.authStatusLabel(s))"
    }

    private var lockTooltip: String {
        engine.autoStartWhenLocked
            ? loc.t("health.lock_armed")
            : loc.t("health.lock_off")
    }
}

/// Version chip always visible on the right half of the bottom status
/// bar (whenever there's a parseable current version). Shape:
///
///   no update:        [v0.1.5]
///   update pending:   [v0.1.5] → [v0.1.6]    (new one amber)
///
/// Current version is clickable → opens the current release page on
/// GitHub. New version is clickable → opens the in-app update sheet
/// with release notes.
private struct UpdateVersionStrip: View {
    let release: UpdateChecker.Release?
    private let loc = Localizer.shared

    var body: some View {
        HStack(spacing: 4) {
            if let current = UpdateChecker.shared.currentDisplayVersion {
                Button {
                    if let url = UpdateChecker.shared.currentReleaseURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(current)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(format: loc.t("update.current_tooltip_fmt"), current))
            }

            if let release {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Button {
                    UpdateChecker.shared.isSheetPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AppColor.statusPending)
                        Text(release.tagName)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.statusPending)
                    }
                }
                .buttonStyle(.plain)
                .help(String(format: loc.t("update.available_tooltip_fmt"), release.displayName))
            }
        }
    }
}

/// Small symbol + color scheme used for each of the three health signals.
/// Active = accent-green; inactive/bad = red (for Photos auth) or dim
/// (for the two toggles that are just off, not broken). The distinction
/// is encoded by the caller: `photosAuthOK == false` passes active=false
/// for a signal that's genuinely red, and we want both visual weights.
private struct HealthIcon: View {
    let symbol: String
    let active: Bool
    let tooltip: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(active ? AppColor.statusDone : Color.secondary.opacity(0.55))
            .help(tooltip)
            .accessibilityLabel(tooltip)
    }
}

