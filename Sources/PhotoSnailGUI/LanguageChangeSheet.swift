import SwiftUI
import PhotoSnailCore

/// Multi-step dialog flow for changing the app language.
///
/// Steps:
/// 1. Confirm language switch (shown in the CURRENT language)
/// 2. If confirmed: switch UI, then ask about prompt language
/// 3. If prompt changed: ask about translating existing descriptions
struct LanguageChangeSheet: View {
    let targetLanguage: Localizer.Language
    let store: LibraryStore
    @Binding var isPresented: Bool

    enum Step {
        case confirmSwitch
        case promptLanguage
        case translateExisting
        case done
    }

    @State private var step: Step = .confirmSwitch
    @State private var translationQueued: Int = 0
    private let loc = Localizer.shared

    var body: some View {
        VStack(spacing: Spacing.lg) {
            switch step {
            case .confirmSwitch:
                confirmSwitchView
            case .promptLanguage:
                promptLanguageView
            case .translateExisting:
                translateExistingView
            case .done:
                doneView
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
    }

    // MARK: - Step 1: Confirm language switch

    private var confirmSwitchView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "globe")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text(loc.t("lang.confirm_title"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(String(format: "%@ → %@",
                        loc.language.nativeName,
                        targetLanguage.nativeName))
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack {
                Button(loc.t("button.cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(loc.t("lang.confirm_change")) {
                    // Switch UI language
                    loc.language = targetLanguage
                    step = .promptLanguage
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 2: Change prompt language?

    private var promptLanguageView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "text.bubble")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text(loc.t("lang.prompt_title"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(loc.t("lang.prompt_message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button(loc.t("button.skip")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(loc.t("lang.confirm_change")) {
                    Task { await changePromptLanguage() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 3: Translate existing descriptions?

    private var translateExistingView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text(loc.t("lang.translate_title"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(loc.t("lang.translate_message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button(loc.t("button.skip")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(loc.t("lang.translate")) {
                    Task { await enqueueTranslation() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text(String(format: loc.t("status.translation_queued"), translationQueued))
                .font(.title3)

            Button(loc.t("button.close")) {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func changePromptLanguage() async {
        guard let engine = store.engine else {
            isPresented = false
            return
        }

        // Set the custom prompt to the pre-translated template for the target
        // language and bump the active family's sentinel so new results are
        // distinguishable from those written under the old prompt.
        let newPrompt = Localizer.promptTemplate(for: targetLanguage)
        let activeFamily = Sentinel.shortFamily(of: engine.model)

        var configs = engine.settingsSnapshot.modelConfigs
        var cfg = configs[activeFamily] ?? ModelConfig()
        cfg.customPrompt = newPrompt
        cfg.promptLanguage = targetLanguage.code
        if cfg.customSentinel == nil {
            cfg.sentinelVersion = max(cfg.sentinelVersion + 1, 1)
        }
        configs[activeFamily] = cfg

        await engine.applyConfigChange(
            model: engine.model,
            apiProvider: engine.apiProvider,
            ollama: engine.connection,
            openai: engine.openaiConnection,
            modelConfigs: configs
        )

        step = .translateExisting
    }

    private func enqueueTranslation() async {
        guard let engine = store.engine else {
            isPresented = false
            return
        }

        do {
            // Get all done rows with any sentinel (they all need translation)
            let sentinels = try await engine.queue.distinctSentinels()
            var totalQueued = 0
            for sentinel in sentinels {
                let ids = try await engine.queue.idsWithSentinel(sentinel)
                if !ids.isEmpty {
                    try await engine.queue.enqueueTranslation(ids)
                    totalQueued += ids.count
                }
            }
            translationQueued = totalQueued
            step = .done
        } catch {
            // Best effort — close on failure
            isPresented = false
        }
    }
}
