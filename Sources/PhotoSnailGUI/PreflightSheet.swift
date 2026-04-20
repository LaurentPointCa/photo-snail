import SwiftUI
import PhotoSnailCore

/// Blocking sheet surfaced at app launch when the LLM preflight fails.
///
/// Two failure shapes:
///   - `.unreachable(reason:)` — daemon not running / wrong URL / network
///   - `.modelMissing(installed:)` — daemon reachable but configured model
///     isn't pulled / loaded yet
///
/// Copy, fix-instructions, and the Start-Ollama affordance all branch on
/// `provider`. For `.openaiCompatible` (locally-hosted mlx-vlm / LM Studio /
/// vLLM), there's no canonical boot command so the fix block renders plain
/// guidance bullets instead of copy-paste shell commands.
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
    let provider: LLMProvider
    @Bindable var engine: ProcessingEngine
    @Binding var isPresented: Bool

    private var onOpenSettings: () -> Void

    /// Tracks the "Start Ollama" button's in-progress state so the UI
    /// reflects the ~2 s we wait between launching `Ollama.app` and
    /// re-running the preflight.
    @State private var isStartingOllama: Bool = false

    init(result: OllamaClient.PreflightResult, model: String, baseURL: URL,
         provider: LLMProvider,
         engine: ProcessingEngine, isPresented: Binding<Bool>,
         onOpenSettings: @escaping () -> Void) {
        self.result = result
        self.model = model
        self.baseURL = baseURL
        self.provider = provider
        self.engine = engine
        self._isPresented = isPresented
        self.onOpenSettings = onOpenSettings
    }

    /// Only show the Start-Ollama button when the failure is "can't reach"
    /// AND the current provider is Ollama. OpenAI-compatible servers don't
    /// have a one-click boot affordance — user has to start their own.
    private var canStartOllama: Bool {
        guard provider == .ollama else { return false }
        if case .unreachable = result { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 28))
                Text(loc.t(k("preflight.title")))
                    .font(.title2).bold()
            }

            switch result {
            case .ok:
                // Shouldn't render — caller gates on failure — but keep something
                // useful rather than crashing.
                Text(loc.t("preflight.ok"))
            case .unreachable(let reason):
                Text(loc.t(k("preflight.unreachable_heading")))
                    .font(.headline)
                Text(String(format: loc.t(k("preflight.unreachable_body")), baseURL.absoluteString, reason))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                fixBlock(unreachable: true)
            case .modelMissing(let installed):
                Text(String(format: loc.t(k("preflight.model_missing_heading")), model))
                    .font(.headline)
                if installed.isEmpty {
                    Text(loc.t(k("preflight.model_missing_none_installed")))
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(loc.t(k("preflight.model_missing_installed_list")))
                        .font(.body)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(installed, id: \.self) { name in
                            Text("  • \(name)").font(.system(.body, design: .monospaced))
                        }
                    }
                }
                fixBlock(unreachable: false)
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
                if canStartOllama {
                    Button {
                        Task { await startOllamaAndRetry() }
                    } label: {
                        if isStartingOllama {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(loc.t("preflight.starting_ollama"))
                            }
                        } else {
                            Text(loc.t("preflight.start_ollama"))
                        }
                    }
                    .disabled(isStartingOllama)
                }
                Button(loc.t("preflight.retry")) {
                    Task {
                        await engine.runPreflight()
                        // If the retry passed, the sheet owner flips
                        // isPresented to false via the status observer.
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isStartingOllama)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    /// Resolve a base localization key to its provider-specific variant.
    /// For `.ollama` we keep the existing (original) keys — no `_ollama`
    /// suffix — so the pre-existing translations keep working unchanged.
    /// For `.openaiCompatible` we route to `<key>_openai` variants added
    /// when the provider abstraction shipped.
    private func k(_ base: String) -> String {
        switch provider {
        case .ollama: return base
        case .openaiCompatible: return base + "_openai"
        }
    }

    /// Render the "how to fix this" block under the error heading. Ollama
    /// gets copy-paste shell commands (brew/serve/pull) because there's a
    /// canonical workflow. OpenAI-compatible gets plain guidance bullets —
    /// the user is running mlx-vlm / LM Studio / vLLM and we don't know
    /// which, so no canned command is safe.
    @ViewBuilder
    private func fixBlock(unreachable: Bool) -> some View {
        switch provider {
        case .ollama:
            if unreachable {
                FixCommands(lines: [
                    "brew install ollama",
                    "ollama serve",
                    "ollama pull \(model)",
                ])
            } else {
                FixCommands(lines: ["ollama pull \(model)"])
            }
        case .openaiCompatible:
            let lines: [String] = unreachable
                ? [loc.t("preflight.openai_fix_check_running"),
                   loc.t("preflight.openai_fix_check_url"),
                   loc.t("preflight.openai_fix_load_model")]
                : [loc.t("preflight.openai_fix_load_model"),
                   loc.t("preflight.openai_fix_check_model_id")]
            FixBullets(lines: lines)
        }
    }

    /// Launch `Ollama.app` (boots the menubar icon + HTTP daemon), wait
    /// ~1.5 s for the daemon to start accepting connections, then re-run
    /// the preflight. If Ollama.app isn't installed, `tryStartLocalOllama`
    /// returns false and we still retry so the user sees an up-to-date
    /// error without having to click Retry manually.
    private func startOllamaAndRetry() async {
        isStartingOllama = true
        let started = OllamaClient.tryStartLocalOllama()
        if started {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        await engine.runPreflight()
        isStartingOllama = false
    }
}

/// Guidance bullets for providers that don't have a canned command line.
/// Used by the OpenAI-compatible branch where the user might be running
/// mlx-vlm, LM Studio, or vLLM and we don't know which.
private struct FixBullets: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
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
