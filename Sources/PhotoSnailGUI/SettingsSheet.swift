import SwiftUI
import PhotoSnailCore

/// Settings sheet — provider, model list (one row per family with inline
/// prompt + sentinel editor), and the shared connection block.
///
/// Each row in the Models list represents one model family. A single radio
/// marks which model is "active" — the one the worker will use on the next
/// Start. Rows expand inline to reveal that family's prompt + sentinel; the
/// active row is expanded by default.
///
/// Edits are local to this view until the user clicks `Save`, which flows
/// through `engine.applyConfigChange(...)` and persists the full
/// `modelConfigs` dict so every family's settings survive.
struct SettingsSheet: View {
    let engine: ProcessingEngine
    @Binding var isPresented: Bool
    private let loc = Localizer.shared

    // MARK: - Draft state

    /// Provider selection (segmented at top of the sheet).
    @State private var draftProvider: LLMProvider = .ollama

    /// The model id that will be saved as `settings.model` (the active one).
    @State private var draftActiveModel: String = ""

    /// Per-family drafts. Saves flow through this dict so editing family A's
    /// prompt doesn't clobber family B's config.
    @State private var draftConfigs: [String: ModelConfig] = [:]

    /// Which specific tag a family will use when activated. Only displayed
    /// when >1 tag is installed for a family. Defaults to the active model
    /// on load, else the first installed tag in that family.
    @State private var tagInFamily: [String: String] = [:]

    /// Families whose row is currently expanded.
    @State private var expandedFamilies: Set<String> = []

    /// Families whose sentinel "pencil" has been clicked (custom override
    /// field is shown). Independent of expansion.
    @State private var editingSentinelFor: Set<String> = []

    // Connection fields
    @State private var draftOllamaBaseURL: String = ""
    @State private var draftOllamaAPIKey: String = ""
    @State private var draftOllamaHeaders: [HeaderEntry] = []
    @State private var showOllamaAPIKey: Bool = false
    @State private var showOllamaAdvancedHeaders: Bool = false

    @State private var draftOpenAIBaseURL: String = ""
    @State private var draftOpenAIAPIKey: String = ""
    @State private var draftOpenAIHeaders: [HeaderEntry] = []
    @State private var showOpenAIAPIKey: Bool = false
    @State private var showOpenAIAdvancedHeaders: Bool = false

    // Requeue dialog state
    @State private var showRequeueDialog: Bool = false
    @State private var availableSentinels: [String] = []
    @State private var selectedSentinelsForRequeue: Set<String> = []

    // Test connection state
    @State private var testInProgress: Bool = false
    @State private var testResult: TestResult? = nil

    enum TestResult {
        case success(Int)
        case failure(String)
    }

    struct HeaderEntry: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    SurfaceCard { providerAndConnectionSection }
                    SurfaceCard { modelsSection }
                }
                .padding(Spacing.lg)
            }
            .sheet(isPresented: $showRequeueDialog) { requeueSheet }
            Divider()
            footer
        }
        .frame(width: 640, height: 780)
        .onAppear { loadFromEngine() }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            Text(loc.t("settings.title"))
                .font(.title)
                .fontWeight(.semibold)
            Spacer()
            Button(loc.t("button.close")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.lg)
    }

    private var footer: some View {
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

    // MARK: - Provider + Connection (combined card)

    /// Provider picker at the top, directly followed by the connection
    /// fields for the currently-selected provider. Keeping them in one
    /// card keeps the "pick a backend → point at it → test" flow contiguous.
    private var providerAndConnectionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader(loc.t("section.provider"), systemImage: "server.rack")

            Picker("", selection: $draftProvider) {
                Text(loc.t("provider.ollama")).tag(LLMProvider.ollama)
                Text(loc.t("provider.openai_compatible")).tag(LLMProvider.openaiCompatible)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: draftProvider) { _, _ in
                testResult = nil
                Task {
                    await engine.refreshAvailableModels()
                    // If the active model isn't valid for the new provider,
                    // auto-pick the first installed one.
                    if !engine.availableModels.contains(where: { $0.name == draftActiveModel }) {
                        if let first = engine.availableModels.first {
                            draftActiveModel = first.name
                            let fam = Sentinel.shortFamily(of: first.name)
                            ensureConfigExists(for: fam)
                            expandedFamilies = [fam]
                        } else {
                            draftActiveModel = ""
                            expandedFamilies = []
                        }
                    }
                }
            }

            Text(loc.t("provider.help"))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, Spacing.xs)

            connectionSection
        }
    }

    // MARK: - Models list

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader(loc.t("settings.families_header"), systemImage: "cpu")

            Text(loc.t("settings.per_family_hint"))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if orderedFamilies.isEmpty {
                modelListLoadingOrEmpty
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(orderedFamilies.enumerated()), id: \.element) { idx, family in
                        modelRow(family)
                        if idx < orderedFamilies.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(AppColor.surfaceSunken, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppColor.borderSubtle, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var modelListLoadingOrEmpty: some View {
        if engine.modelsLoadError != nil {
            Label(engine.modelsLoadError ?? "",
                  systemImage: "exclamationmark.triangle")
                .font(AppFont.caption)
                .foregroundStyle(.orange)
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text(loc.t("settings.loading_models"))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One collapsible row in the Models list.
    @ViewBuilder
    private func modelRow(_ family: String) -> some View {
        let expanded = expandedFamilies.contains(family)
        let isActiveFamily = !draftActiveModel.isEmpty
            && Sentinel.shortFamily(of: draftActiveModel) == family
        let tagsForFamily = installedTags(in: family)
        let representativeModel = representativeTag(for: family, tags: tagsForFamily)
        let isInstalled = !tagsForFamily.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header — always visible.
            modelRowHeader(
                family: family,
                representativeModel: representativeModel,
                isActiveFamily: isActiveFamily,
                isInstalled: isInstalled,
                expanded: expanded
            )

            // Expanded body.
            if expanded {
                modelRowBody(
                    family: family,
                    tags: tagsForFamily,
                    isActiveFamily: isActiveFamily
                )
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
            }
        }
    }

    /// Header: radio, title, badges, chevron. Whole-row click toggles expansion.
    private func modelRowHeader(family: String,
                                representativeModel: String,
                                isActiveFamily: Bool,
                                isInstalled: Bool,
                                expanded: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            // Radio — its own Button so it doesn't bubble to the row's
            // expand/collapse action.
            Button {
                activateFamily(family)
            } label: {
                Image(systemName: isActiveFamily ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActiveFamily ? Color.accentColor : Color.secondary.opacity(0.6))
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(isActiveFamily ? loc.t("settings.active_badge") : loc.t("settings.use_this_model"))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.sm) {
                    Text(representativeModel.isEmpty ? family : representativeModel)
                        .font(AppFont.bodyEmphasized)
                        .foregroundStyle(AppColor.textPrimary)
                    if isActiveFamily {
                        Text(loc.t("settings.active_badge"))
                            .font(AppFont.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if !isInstalled {
                        Label(loc.t("settings.not_installed"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(AppFont.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .animation(.easeInOut(duration: 0.15), value: expanded)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpansion(family) }
    }

    /// Expanded body: tag picker (if multiple), prompt editor, sentinel.
    private func modelRowBody(family: String,
                              tags: [String],
                              isActiveFamily: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if tags.count > 1 {
                tagPicker(family: family, tags: tags, isActiveFamily: isActiveFamily)
            }
            promptEditor(family: family)
            sentinelEditor(family: family)
        }
    }

    /// Small picker shown only when a family has multiple installed tags.
    private func tagPicker(family: String,
                           tags: [String],
                           isActiveFamily: Bool) -> some View {
        let current = tagInFamily[family]
            ?? (isActiveFamily ? draftActiveModel : tags.first ?? "")

        return HStack {
            Text(loc.t("settings.tag_label"))
                .font(AppFont.label)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { current },
                set: { newValue in
                    tagInFamily[family] = newValue
                    if isActiveFamily {
                        draftActiveModel = newValue
                    }
                }
            )) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag).tag(tag)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()
        }
    }

    private func promptEditor(family: String) -> some View {
        let familyDefault = PromptBuilder.defaultPrompt(forFamily: family)
        let binding = Binding<String>(
            get: {
                draftConfigs[family]?.customPrompt ?? familyDefault
            },
            set: { newValue in
                var cfg = draftConfigs[family] ?? ModelConfig()
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let defaultTrimmed = familyDefault
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cfg.customPrompt = (trimmed == defaultTrimmed) ? nil : newValue
                draftConfigs[family] = cfg
            }
        )
        let isDefault = (draftConfigs[family]?.customPrompt == nil)
        let promptChanged = self.promptDiffersFromDisk(family: family)

        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(loc.t("section.prompt"))
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("button.reset_to_default")) {
                    var cfg = draftConfigs[family] ?? ModelConfig()
                    cfg.customPrompt = nil
                    draftConfigs[family] = cfg
                }
                .disabled(isDefault)
                .buttonStyle(.borderless)
                .font(AppFont.caption)
            }

            TextEditor(text: binding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 180)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            if promptChanged {
                let nextVersion = (draftConfigs[family]?.sentinelVersion ?? 1) + 1
                let nextSentinel = Sentinel.make(family: family, version: nextVersion)
                Text(String(format: loc.t("settings.prompt_bump_hint"), nextSentinel))
                    .font(AppFont.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sentinelEditor(family: String) -> some View {
        let cfg = draftConfigs[family] ?? ModelConfig()
        let canonical = Sentinel.make(family: family, version: cfg.sentinelVersion)
        let effective = (cfg.customSentinel?.isEmpty == false) ? cfg.customSentinel! : canonical
        let isEditing = editingSentinelFor.contains(family)
        let hasCustomSentinel = cfg.customSentinel?.isEmpty == false

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(loc.t("section.sentinel"))
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)

                Text(effective)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AppColor.textPrimary)

                Spacer()

                Button {
                    if isEditing {
                        editingSentinelFor.remove(family)
                    } else {
                        editingSentinelFor.insert(family)
                    }
                } label: {
                    Image(systemName: isEditing ? "xmark.circle" : "pencil")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help(loc.t("settings.sentinel_edit_help"))
            }

            if isEditing {
                HStack(spacing: Spacing.sm) {
                    TextField(loc.t("settings.sentinel_placeholder"),
                              text: Binding(
                                get: { draftConfigs[family]?.customSentinel ?? "" },
                                set: {
                                    var c = draftConfigs[family] ?? ModelConfig()
                                    c.customSentinel = $0.isEmpty ? nil : $0
                                    draftConfigs[family] = c
                                }
                              ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    if hasCustomSentinel {
                        Button(loc.t("settings.revert_sentinel")) {
                            var c = draftConfigs[family] ?? ModelConfig()
                            c.customSentinel = nil
                            draftConfigs[family] = c
                            editingSentinelFor.remove(family)
                        }
                        .buttonStyle(.borderless)
                        .font(AppFont.caption)
                    }
                }
            }
        }
    }

    // MARK: - Connection (unchanged from previous version)

    @ViewBuilder
    private var connectionSection: some View {
        switch draftProvider {
        case .ollama: ollamaConnectionSection
        case .openaiCompatible: openaiConnectionSection
        }
    }

    private var ollamaConnectionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader(loc.t("section.ollama_connection"), systemImage: "network")

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(loc.t("settings.base_url"))
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                TextField("http://localhost:11434", text: $draftOllamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            apiKeyField(title: loc.t("settings.api_key"),
                        placeholder: loc.t("settings.api_key_placeholder"),
                        help: loc.t("settings.api_key_help"),
                        key: $draftOllamaAPIKey,
                        show: $showOllamaAPIKey)

            headersDisclosure(expanded: $showOllamaAdvancedHeaders,
                              entries: $draftOllamaHeaders)

            testConnectionRow
        }
    }

    private var openaiConnectionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            settingsSectionHeader(loc.t("section.openai_connection"), systemImage: "network")

            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.medium)
                Text(loc.t("settings.openai_local_only_banner"))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.sm)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(loc.t("settings.base_url"))
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                TextField("http://host.local:9090/v1", text: $draftOpenAIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            apiKeyField(title: loc.t("settings.api_key"),
                        placeholder: loc.t("settings.openai_api_key_placeholder"),
                        help: loc.t("settings.openai_api_key_help"),
                        key: $draftOpenAIAPIKey,
                        show: $showOpenAIAPIKey)

            headersDisclosure(expanded: $showOpenAIAdvancedHeaders,
                              entries: $draftOpenAIHeaders)

            testConnectionRow
        }
    }

    @ViewBuilder
    private func apiKeyField(title: String,
                             placeholder: String,
                             help: String,
                             key: Binding<String>,
                             show: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(AppFont.label)
                .foregroundStyle(.secondary)
            HStack {
                Group {
                    if show.wrappedValue {
                        TextField(placeholder, text: key)
                    } else {
                        SecureField(placeholder, text: key)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                Button {
                    show.wrappedValue.toggle()
                } label: {
                    Image(systemName: show.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
            Text(help)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func headersDisclosure(expanded: Binding<Bool>,
                                   entries: Binding<[HeaderEntry]>) -> some View {
        DisclosureGroup(loc.t("settings.advanced_headers"), isExpanded: expanded) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(loc.t("settings.advanced_headers_help"))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                ForEach(entries) { $entry in
                    HStack {
                        TextField(loc.t("settings.header_name"), text: $entry.key)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        TextField(loc.t("settings.header_value"), text: $entry.value)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button {
                            entries.wrappedValue.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    entries.wrappedValue.append(HeaderEntry(key: "", value: ""))
                } label: {
                    Label(loc.t("button.add_header"), systemImage: "plus.circle")
                        .font(AppFont.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 4)
        }
    }

    private var testConnectionRow: some View {
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
                        .font(AppFont.caption)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(AppFont.caption)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }

    // MARK: - Requeue sheet (unchanged)

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
            } catch { /* best effort */ }
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

    // MARK: - Row-model helpers

    /// Installed tags whose family matches `family`, sorted alphabetically.
    private func installedTags(in family: String) -> [String] {
        engine.availableModels
            .filter { Sentinel.shortFamily(of: $0.name) == family }
            .map(\.name)
            .sorted()
    }

    /// The model id to show in a row header.
    /// Priority: active model (if in this family) → user-pinned tag → first installed → "".
    private func representativeTag(for family: String, tags: [String]) -> String {
        if !draftActiveModel.isEmpty && Sentinel.shortFamily(of: draftActiveModel) == family {
            return draftActiveModel
        }
        if let pinned = tagInFamily[family], !pinned.isEmpty {
            return pinned
        }
        return tags.first ?? ""
    }

    /// Display order: active family first, then alphabetical.
    private var orderedFamilies: [String] {
        var set = Set<String>()
        for fam in draftConfigs.keys { set.insert(fam) }
        for m in engine.availableModels { set.insert(Sentinel.shortFamily(of: m.name)) }
        if !draftActiveModel.isEmpty {
            set.insert(Sentinel.shortFamily(of: draftActiveModel))
        }

        let sorted = set.sorted()
        guard !draftActiveModel.isEmpty else { return sorted }
        let active = Sentinel.shortFamily(of: draftActiveModel)
        guard sorted.contains(active) else { return sorted }
        return [active] + sorted.filter { $0 != active }
    }

    private func ensureConfigExists(for family: String) {
        if draftConfigs[family] == nil {
            draftConfigs[family] = ModelConfig()
        }
    }

    private func toggleExpansion(_ family: String) {
        ensureConfigExists(for: family)
        if expandedFamilies.contains(family) {
            expandedFamilies.remove(family)
        } else {
            expandedFamilies.insert(family)
        }
    }

    /// Make the family the active one. If the user had pinned a specific tag
    /// for this family, use that; else use the first installed tag; else
    /// leave the active model unchanged (and show the warning badge).
    private func activateFamily(_ family: String) {
        ensureConfigExists(for: family)
        if let pinned = tagInFamily[family], !pinned.isEmpty {
            draftActiveModel = pinned
        } else if let first = installedTags(in: family).first {
            draftActiveModel = first
            tagInFamily[family] = first
        } else {
            // No installed tags — keep `draftActiveModel` as the family name
            // so the preflight error message can tell the user to install it.
            draftActiveModel = family
        }
        // Expand the newly-activated row for immediate feedback.
        expandedFamilies.insert(family)
    }

    /// Does the draft prompt differ from what's on disk for this family?
    private func promptDiffersFromDisk(family: String) -> Bool {
        let draft = draftConfigs[family]?.customPrompt ?? ""
        let onDisk = engine.settingsSnapshot.modelConfigs[family]?.customPrompt ?? ""
        return draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != onDisk.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Load / Save

    private func loadFromEngine() {
        let snapshot = engine.settingsSnapshot

        draftActiveModel = snapshot.model
        draftProvider = snapshot.apiProvider
        draftConfigs = snapshot.modelConfigs

        // Ensure the active family has an entry so bindings don't hit nil.
        let activeFam = Sentinel.shortFamily(of: draftActiveModel)
        ensureConfigExists(for: activeFam)

        // Seed tagInFamily with the active model + one tag per installed family.
        tagInFamily[activeFam] = draftActiveModel
        for m in engine.availableModels {
            let fam = Sentinel.shortFamily(of: m.name)
            if tagInFamily[fam] == nil {
                tagInFamily[fam] = m.name
            }
        }

        // Start with only the active row expanded.
        expandedFamilies = [activeFam]
        editingSentinelFor = []

        draftOllamaBaseURL = engine.connection.baseURL.absoluteString
        draftOllamaAPIKey = engine.connection.apiKey ?? ""
        draftOllamaHeaders = engine.connection.headers
            .map { HeaderEntry(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }

        draftOpenAIBaseURL = engine.openaiConnection.baseURL.absoluteString
        draftOpenAIAPIKey = engine.openaiConnection.apiKey ?? ""
        draftOpenAIHeaders = engine.openaiConnection.headers
            .map { HeaderEntry(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }

        testResult = nil
    }

    private func currentDraftOllamaConnection() -> OllamaConnection? {
        guard let url = URL(string: draftOllamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else {
            return nil
        }
        var headers: [String: String] = [:]
        for entry in draftOllamaHeaders {
            let k = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            headers[k] = entry.value
        }
        let trimmedKey = draftOllamaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return OllamaConnection(
            baseURL: url,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            headers: headers
        )
    }

    private func currentDraftOpenAIConnection() -> OpenAIConnection? {
        guard let url = URL(string: draftOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else {
            return nil
        }
        var headers: [String: String] = [:]
        for entry in draftOpenAIHeaders {
            let k = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            headers[k] = entry.value
        }
        let trimmedKey = draftOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAIConnection(
            baseURL: url,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            headers: headers
        )
    }

    private func testConnection() async {
        testInProgress = true
        testResult = nil
        defer { testInProgress = false }

        // Short request timeout for the test specifically — the regular
        // generateCaption timeout is 1800 s to tolerate slow vision runs,
        // but a reachability probe that takes longer than ~15 s means the
        // endpoint is wrong or down. Hanging the UI for 30 min is no good.
        let testTimeout: TimeInterval = 15

        let client: any LLMClient
        switch draftProvider {
        case .ollama:
            guard let conn = currentDraftOllamaConnection() else {
                testResult = .failure(loc.t("settings.invalid_url"))
                return
            }
            client = OllamaClient(connection: conn, timeoutSeconds: testTimeout)
        case .openaiCompatible:
            guard let conn = currentDraftOpenAIConnection() else {
                testResult = .failure(loc.t("settings.invalid_url"))
                return
            }
            client = OpenAIClient(connection: conn, timeoutSeconds: testTimeout)
        }
        do {
            let models = try await client.listModels()
            testResult = .success(models.count)
        } catch {
            testResult = .failure("\(error)")
        }
    }

    private func save() async {
        guard let ollamaConn = currentDraftOllamaConnection() else {
            testResult = .failure(loc.t("settings.invalid_url_save"))
            return
        }
        guard let openaiConn = currentDraftOpenAIConnection() else {
            testResult = .failure(loc.t("settings.invalid_url_save"))
            return
        }

        // Capture old sentinel for the active family BEFORE we bump.
        let activeFam = Sentinel.shortFamily(of: draftActiveModel)
        let oldSentinel: String
        if let prev = engine.settingsSnapshot.modelConfigs[activeFam] {
            if let custom = prev.customSentinel, !custom.isEmpty {
                oldSentinel = custom
            } else {
                oldSentinel = Sentinel.make(family: activeFam, version: prev.sentinelVersion)
            }
        } else {
            oldSentinel = engine.sentinel
        }

        // Bump sentinel versions for every family whose prompt changed vs
        // on-disk (and doesn't have a custom sentinel pin). A bump on a
        // non-active family is harmless — the new version only surfaces
        // when the user actually activates that family.
        var finalConfigs = draftConfigs
        for (family, cfg) in finalConfigs {
            guard promptDiffersFromDisk(family: family) else { continue }
            guard cfg.customSentinel?.isEmpty != false else { continue }
            var updated = cfg
            updated.sentinelVersion = max(cfg.sentinelVersion + 1, 1)
            finalConfigs[family] = updated
        }

        await engine.applyConfigChange(
            model: draftActiveModel,
            apiProvider: draftProvider,
            ollama: ollamaConn,
            openai: openaiConn,
            modelConfigs: finalConfigs
        )

        // Requeue prompt if the sentinel the app will write changed.
        let newSentinel = engine.sentinel
        if newSentinel != oldSentinel {
            do {
                let sentinels = try await engine.queue.distinctSentinels()
                let oldSentinels = sentinels.filter { $0 != newSentinel }
                if !oldSentinels.isEmpty {
                    availableSentinels = oldSentinels
                    selectedSentinelsForRequeue = []
                    showRequeueDialog = true
                    return
                }
            } catch { /* best effort */ }
        }

        isPresented = false
    }
}
