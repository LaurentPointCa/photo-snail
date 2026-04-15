import SwiftUI
import PhotoSnailCore

/// Blocking sheet surfaced at app launch when the Ollama preflight fails.
///
/// Two failure shapes:
///   - `.unreachable(reason:)` — daemon not running / wrong URL / network
///   - `.modelMissing(installed:)` — daemon reachable but configured model
///     isn't pulled yet
///
/// Actions:
///   - Retry — re-runs the preflight and closes the sheet on success
///   - Continue anyway — flips status to `.dismissed` so the user can explore
///     the library view; subsequent preflight failures this session stay silent
///   - Open Settings — user can change model/connection without quitting
struct PreflightSheet: View {
    private let loc = Localizer.shared
    let result: OllamaClient.PreflightResult
    let model: String
    let baseURL: URL
    @Bindable var engine: ProcessingEngine
    @Binding var isPresented: Bool

    private var onOpenSettings: () -> Void

    init(result: OllamaClient.PreflightResult, model: String, baseURL: URL,
         engine: ProcessingEngine, isPresented: Binding<Bool>,
         onOpenSettings: @escaping () -> Void) {
        self.result = result
        self.model = model
        self.baseURL = baseURL
        self.engine = engine
        self._isPresented = isPresented
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 28))
                Text(loc.t("preflight.title"))
                    .font(.title2).bold()
            }

            switch result {
            case .ok:
                // Shouldn't render — caller gates on failure — but keep something
                // useful rather than crashing.
                Text(loc.t("preflight.ok"))
            case .unreachable(let reason):
                Text(loc.t("preflight.unreachable_heading"))
                    .font(.headline)
                Text(String(format: loc.t("preflight.unreachable_body"), baseURL.absoluteString, reason))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FixCommands(lines: [
                    "brew install ollama",
                    "ollama serve",
                    "ollama pull \(model)",
                ])
            case .modelMissing(let installed):
                Text(String(format: loc.t("preflight.model_missing_heading"), model))
                    .font(.headline)
                if installed.isEmpty {
                    Text(loc.t("preflight.model_missing_none_installed"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(loc.t("preflight.model_missing_installed_list"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(installed, id: \.self) { name in
                            Text("  • \(name)").font(.system(.body, design: .monospaced))
                        }
                    }
                }
                FixCommands(lines: ["ollama pull \(model)"])
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button(loc.t("preflight.open_settings")) {
                    isPresented = false
                    onOpenSettings()
                }
                Spacer()
                Button(loc.t("preflight.continue_anyway")) {
                    engine.dismissPreflight()
                    isPresented = false
                }
                Button(loc.t("preflight.retry")) {
                    Task {
                        await engine.runPreflight()
                        // If the retry passed, the sheet owner flips
                        // isPresented to false via the status observer.
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// Small copy-paste-friendly command block.
private struct FixCommands: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                HStack {
                    Text(line)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
