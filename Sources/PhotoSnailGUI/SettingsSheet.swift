import SwiftUI
import PhotoSnailCore

/// Settings sheet — model picker, sentinel choice, Ollama connection.
///
/// Opens from the toolbar gear button. Edits are local to this view until the
/// user clicks `Save`, which calls `engine.applyConfigChange(...)` to persist
/// to settings.json. Changes take effect on the NEXT `Start` — they do not
/// interrupt a running batch.
struct SettingsSheet: View {
    let engine: ProcessingEngine
    @Binding var isPresented: Bool

    // MARK: - Local edit state

    @State private var draftModel: String = ""
    @State private var draftSentinel: String = ""
    @State private var draftBaseURL: String = ""
    @State private var draftAPIKey: String = ""
    @State private var draftHeaders: [HeaderEntry] = []
    @State private var showAPIKey: Bool = false
    @State private var showAdvancedHeaders: Bool = false

    // Test-connection state
    @State private var testInProgress: Bool = false
    @State private var testResult: TestResult? = nil

    // Sentinel choice state — appears when the picked model has a different family
    // than the current sentinel.
    @State private var sentinelChoice: SentinelChoice = .keepCurrent

    enum SentinelChoice: Hashable {
        case keepCurrent
        case proposeNew
        case custom
    }

    enum TestResult {
        case success(Int)        // model count
        case failure(String)     // error message
    }

    struct HeaderEntry: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title)
                    .fontWeight(.semibold)
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    SurfaceCard { modelSection }
                    SurfaceCard { sentinelSection }
                    SurfaceCard { ollamaConnectionSection }
                }
                .padding(Spacing.lg)
            }

            Divider()

            // Footer
            HStack {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("Changes apply on next Start")
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.lg)
        }
        .frame(width: 580, height: 720)
        .onAppear { loadFromEngine() }
    }

    // MARK: - Sections

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader("Model", systemImage: "cpu")

            if engine.availableModels.isEmpty {
                if let err = engine.modelsLoadError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading models from Ollama…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Model name (e.g. gemma4:31b)", text: $draftModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftModel) { _, _ in updateSentinelChoice() }
            } else {
                Picker("", selection: $draftModel) {
                    // Include the current model even if Ollama doesn't see it (offline / not installed).
                    if !engine.availableModels.contains(where: { $0.name == draftModel }) && !draftModel.isEmpty {
                        Text("\(draftModel) (current, not in Ollama)").tag(draftModel)
                    }
                    ForEach(engine.availableModels) { m in
                        Text("\(m.name)  —  \(m.sizeLabel)").tag(m.name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: draftModel) { _, _ in updateSentinelChoice() }

                Button {
                    Task { await engine.refreshAvailableModels() }
                } label: {
                    Label("Refresh model list", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var sentinelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader("Sentinel", systemImage: "number")

            let proposed = Sentinel.propose(forModel: draftModel, currentSentinel: engine.sentinel)

            if proposed == nil {
                // Family unchanged — sentinel stays the same.
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(draftSentinel.isEmpty ? engine.sentinel : draftSentinel)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                }
                Text("Same model family — sentinel unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let proposed = proposed {
                // Family changed — show the choice picker.
                Text("This model is a different family from the current sentinel. Pick one:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Sentinel choice", selection: $sentinelChoice) {
                    HStack {
                        Text("Keep current:")
                        Text(engine.sentinel).font(.system(.body, design: .monospaced))
                    }.tag(SentinelChoice.keepCurrent)

                    HStack {
                        Text("Use new:")
                        Text(proposed).font(.system(.body, design: .monospaced))
                    }.tag(SentinelChoice.proposeNew)

                    Text("Custom…").tag(SentinelChoice.custom)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: sentinelChoice) { _, new in
                    switch new {
                    case .keepCurrent: draftSentinel = engine.sentinel
                    case .proposeNew:  draftSentinel = proposed
                    case .custom:      break // user types in the field below
                    }
                }

                if sentinelChoice == .custom {
                    TextField("ai:family-v1", text: $draftSentinel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    private var ollamaConnectionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader("Ollama Connection", systemImage: "network")

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Base URL")
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                TextField("http://localhost:11434", text: $draftBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("API Key")
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                HStack {
                    Group {
                        if showAPIKey {
                            TextField("Bearer token (optional)", text: $draftAPIKey)
                        } else {
                            SecureField("Bearer token (optional)", text: $draftAPIKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                Text("Stored in plain text in ~/Library/Application Support/photo-snail/settings.json (0600). Set PHOTO_SNAIL_OLLAMA_API_KEY in your environment to avoid persisting.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced: custom headers", isExpanded: $showAdvancedHeaders) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("For proxies that use non-Bearer auth (Basic, X-API-Key, etc.). Headers override the API key field if both set Authorization.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)

                    ForEach($draftHeaders) { $entry in
                        HStack {
                            TextField("Header name", text: $entry.key)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            TextField("Value", text: $entry.value)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Button {
                                draftHeaders.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button {
                        draftHeaders.append(HeaderEntry(key: "", value: ""))
                    } label: {
                        Label("Add header", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 4)
            }

            HStack {
                Button {
                    Task { await testConnection() }
                } label: {
                    if testInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test connection", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(testInProgress)

                if let result = testResult {
                    switch result {
                    case .success(let n):
                        Label("OK — \(n) model(s) found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsSectionHeader(_ title: String, systemImage: String) -> some View {
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

    private func loadFromEngine() {
        draftModel = engine.model
        draftSentinel = engine.sentinel
        draftBaseURL = engine.connection.baseURL.absoluteString
        draftAPIKey = engine.connection.apiKey ?? ""
        draftHeaders = engine.connection.headers.map { HeaderEntry(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        sentinelChoice = .keepCurrent
        testResult = nil
    }

    private func updateSentinelChoice() {
        // When the user picks a new model that's the same family, the sentinel stays.
        // When it's a new family, default the choice to "proposeNew" since that's
        // the right answer for most users.
        if Sentinel.propose(forModel: draftModel, currentSentinel: engine.sentinel) != nil {
            sentinelChoice = .proposeNew
            if let proposed = Sentinel.propose(forModel: draftModel, currentSentinel: engine.sentinel) {
                draftSentinel = proposed
            }
        } else {
            sentinelChoice = .keepCurrent
            draftSentinel = engine.sentinel
        }
    }

    private func currentDraftConnection() -> OllamaConnection? {
        guard let url = URL(string: draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else {
            return nil
        }
        var headers: [String: String] = [:]
        for entry in draftHeaders {
            let k = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            headers[k] = entry.value
        }
        let trimmedKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return OllamaConnection(
            baseURL: url,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            headers: headers
        )
    }

    private func testConnection() async {
        testInProgress = true
        testResult = nil
        defer { testInProgress = false }

        guard let conn = currentDraftConnection() else {
            testResult = .failure("Invalid base URL")
            return
        }
        let client = OllamaClient(connection: conn)
        do {
            let models = try await client.listModels()
            testResult = .success(models.count)
        } catch {
            testResult = .failure("\(error)")
        }
    }

    private func save() async {
        guard let conn = currentDraftConnection() else {
            testResult = .failure("Invalid base URL — not saved")
            return
        }

        // Resolve sentinel based on the current choice (in case the user
        // never touched the radio buttons).
        let finalSentinel: String
        switch sentinelChoice {
        case .keepCurrent:
            finalSentinel = engine.sentinel
        case .proposeNew:
            finalSentinel = Sentinel.propose(forModel: draftModel, currentSentinel: engine.sentinel)
                ?? engine.sentinel
        case .custom:
            finalSentinel = draftSentinel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? engine.sentinel
                : draftSentinel.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        await engine.applyConfigChange(
            model: draftModel,
            sentinel: finalSentinel,
            connection: conn
        )
        isPresented = false
    }
}
