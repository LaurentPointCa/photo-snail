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
    private let loc = Localizer.shared

    // MARK: - Local edit state

    @State private var draftModel: String = ""
    @State private var draftSentinel: String = ""
    @State private var draftBaseURL: String = ""
    @State private var draftAPIKey: String = ""
    @State private var draftHeaders: [HeaderEntry] = []
    @State private var showAPIKey: Bool = false
    @State private var showAdvancedHeaders: Bool = false

    // Prompt edit state
    @State private var draftPrompt: String = ""
    @State private var promptIsDefault: Bool = true
    @State private var promptChanged: Bool = false

    // Requeue dialog state (shown after save with sentinel bump)
    @State private var showRequeueDialog: Bool = false
    @State private var availableSentinels: [String] = []
    @State private var selectedSentinelsForRequeue: Set<String> = []

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
                Text(loc.t("settings.title"))
                    .font(.title)
                    .fontWeight(.semibold)
                Spacer()
                Button(loc.t("button.close")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    SurfaceCard { modelSection }
                    SurfaceCard { promptSection }
                    SurfaceCard { sentinelSection }
                    SurfaceCard { ollamaConnectionSection }
                }
                .padding(Spacing.lg)
            }
            .sheet(isPresented: $showRequeueDialog) {
                requeueSheet
            }

            Divider()

            // Footer
            HStack {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(loc.t("settings.changes_apply"))
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("button.save")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.lg)
        }
        .frame(width: 580, height: 860)
        .onAppear { loadFromEngine() }
    }

    // MARK: - Sections

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader(loc.t("section.model"), systemImage: "cpu")

            if engine.availableModels.isEmpty {
                if let err = engine.modelsLoadError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(loc.t("settings.loading_models"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField(loc.t("settings.model_placeholder"), text: $draftModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftModel) { _, _ in updateSentinelChoice() }
            } else {
                Picker("", selection: $draftModel) {
                    // Include the current model even if Ollama doesn't see it (offline / not installed).
                    if !engine.availableModels.contains(where: { $0.name == draftModel }) && !draftModel.isEmpty {
                        Text("\(draftModel) \(loc.t("settings.model_not_in_ollama"))").tag(draftModel)
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
                    Label(loc.t("button.refresh_model_list"), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader(loc.t("section.prompt"), systemImage: "text.bubble")

            TextEditor(text: $draftPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 160)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: draftPrompt) { _, newValue in
                    let defaultPrompt = PromptBuilder.defaultPrompt
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaultTrimmed = defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    promptIsDefault = (trimmed == defaultTrimmed)

                    let originalPrompt = (engine.customPrompt ?? PromptBuilder.defaultPrompt)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    promptChanged = (trimmed != originalPrompt)
                }

            HStack {
                Button(loc.t("button.reset_to_default")) {
                    draftPrompt = PromptBuilder.defaultPrompt
                }
                .disabled(promptIsDefault)
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()
            }

            if promptChanged {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loc.t("settings.prompt_changed"))
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sentinelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader(loc.t("section.sentinel"), systemImage: "number")

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
                Text(loc.t("settings.sentinel_unchanged"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let proposed = proposed {
                // Family changed — show the choice picker.
                Text(loc.t("settings.sentinel_family_changed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Sentinel choice", selection: $sentinelChoice) {
                    HStack {
                        Text(loc.t("settings.keep_current"))
                        Text(engine.sentinel).font(.system(.body, design: .monospaced))
                    }.tag(SentinelChoice.keepCurrent)

                    HStack {
                        Text(loc.t("settings.use_new"))
                        Text(proposed).font(.system(.body, design: .monospaced))
                    }.tag(SentinelChoice.proposeNew)

                    Text(loc.t("settings.custom")).tag(SentinelChoice.custom)
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
            settingsSectionHeader(loc.t("section.ollama_connection"), systemImage: "network")

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(loc.t("settings.base_url"))
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                TextField("http://localhost:11434", text: $draftBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(loc.t("settings.api_key"))
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                HStack {
                    Group {
                        if showAPIKey {
                            TextField(loc.t("settings.api_key_placeholder"), text: $draftAPIKey)
                        } else {
                            SecureField(loc.t("settings.api_key_placeholder"), text: $draftAPIKey)
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
                Text(loc.t("settings.api_key_help"))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(loc.t("settings.advanced_headers"), isExpanded: $showAdvancedHeaders) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(loc.t("settings.advanced_headers_help"))
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)

                    ForEach($draftHeaders) { $entry in
                        HStack {
                            TextField(loc.t("settings.header_name"), text: $entry.key)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            TextField(loc.t("settings.header_value"), text: $entry.value)
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
                        Label(loc.t("button.add_header"), systemImage: "plus.circle")
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
                        Label(loc.t("button.test_connection"), systemImage: "bolt.horizontal")
                    }
                }
                .disabled(testInProgress)

                if let result = testResult {
                    switch result {
                    case .success(let n):
                        Label("\(loc.t("settings.test_ok")) — \(n) model(s) found", systemImage: "checkmark.circle.fill")
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

    // MARK: - Requeue Sheet

    private var requeueSheet: some View {
        VStack(spacing: Spacing.lg) {
            Text(loc.t("dialog.requeue_title"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(loc.t("dialog.requeue_description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if availableSentinels.isEmpty {
                Text(loc.t("dialog.no_previous_sentinels"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(availableSentinels, id: \.self) { s in
                        Toggle(isOn: Binding(
                            get: { selectedSentinelsForRequeue.contains(s) },
                            set: { on in
                                if on { selectedSentinelsForRequeue.insert(s) }
                                else { selectedSentinelsForRequeue.remove(s) }
                            }
                        )) {
                            Text(s)
                                .font(.system(.body, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Button(loc.t("button.skip")) { showRequeueDialog = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(loc.t("button.requeue_selected")) {
                    Task { await requeueSelectedSentinels() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSentinelsForRequeue.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 420)
    }

    private func requeueSelectedSentinels() async {
        let queue = engine.queue
        for sentinel in selectedSentinelsForRequeue {
            do {
                let ids = try await queue.idsWithSentinel(sentinel)
                if !ids.isEmpty {
                    try await queue.requeue(ids)
                }
            } catch {
                // Best effort — log but continue
            }
        }
        showRequeueDialog = false
        isPresented = false
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

        draftPrompt = engine.customPrompt ?? PromptBuilder.defaultPrompt
        promptIsDefault = (engine.customPrompt == nil)
        promptChanged = false
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
            testResult = .failure(loc.t("settings.invalid_url"))
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
            testResult = .failure(loc.t("settings.invalid_url_save"))
            return
        }

        // Resolve sentinel based on the current choice (in case the user
        // never touched the radio buttons).
        var finalSentinel: String
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

        // If prompt changed (and sentinel wasn't already bumped by a model family change),
        // auto-bump the sentinel version so new results are distinguishable.
        let sentinelAlreadyChanged = (finalSentinel != engine.sentinel)
        if promptChanged && !sentinelAlreadyChanged {
            if let bumped = Sentinel.bumpVersion(currentSentinel: finalSentinel) {
                finalSentinel = bumped
            }
        }

        // Resolve custom prompt: nil if default, otherwise the draft text.
        let effectivePrompt: String? = promptIsDefault ? nil : draftPrompt

        let oldSentinel = engine.sentinel

        await engine.applyConfigChange(
            model: draftModel,
            sentinel: finalSentinel,
            connection: conn,
            customPrompt: effectivePrompt,
            promptLanguage: engine.promptLanguage
        )

        // If sentinel was bumped (model change or prompt change), offer to
        // requeue photos processed under old sentinels.
        if finalSentinel != oldSentinel {
            do {
                let sentinels = try await engine.queue.distinctSentinels()
                let oldSentinels = sentinels.filter { $0 != finalSentinel }
                if !oldSentinels.isEmpty {
                    availableSentinels = oldSentinels
                    selectedSentinelsForRequeue = []
                    showRequeueDialog = true
                    return // Don't dismiss settings — the requeue sheet dismisses on its own
                }
            } catch { /* best effort */ }
        }

        isPresented = false
    }
}
