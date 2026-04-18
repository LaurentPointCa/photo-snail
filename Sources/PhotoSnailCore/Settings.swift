import Foundation

/// Per-model-family configuration. Keyed by `Sentinel.shortFamily(of:)` in
/// `Settings.modelConfigs` so each family keeps its own prompt, sentinel
/// version, and prompt-language even when the user switches between models.
///
/// The effective (active) values surfaced on `Settings` are derived from the
/// entry matching the current `model`'s short family. Switching model swaps
/// which entry is "active" without losing the old one.
public struct ModelConfig: Codable, Sendable, Equatable {
    /// User-edited prompt override for this family. `nil` → use the default
    /// prompt (`PromptBuilder.defaultPrompt`).
    public var customPrompt: String?

    /// Sentinel version counter for this family. Bumped when the prompt or
    /// prompt language changes so re-processed photos are distinguishable
    /// from ones tagged under the previous prompt. Default 1.
    public var sentinelVersion: Int

    /// Explicit sentinel override. Non-nil means the user picked a custom
    /// value via the "Custom" radio in Settings (or `--sentinel` on the
    /// CLI). Takes precedence over the family+version derivation. Kept
    /// distinct so clearing it falls back to the canonical short form.
    public var customSentinel: String?

    /// Prompt language code (e.g. "en", "fr") driving the
    /// translation-pipeline branch. `nil` → English default.
    public var promptLanguage: String?

    public init(customPrompt: String? = nil,
                sentinelVersion: Int = 1,
                customSentinel: String? = nil,
                promptLanguage: String? = nil) {
        self.customPrompt = customPrompt
        self.sentinelVersion = sentinelVersion
        self.customSentinel = customSentinel
        self.promptLanguage = promptLanguage
    }
}

/// Persistent user settings shared by the CLI and GUI.
///
/// Stored as JSON at `~/Library/Application Support/photo-snail/settings.json`
/// with `0600` permissions. API keys are plain text on disk — the tradeoff is
/// documented in CLAUDE.md. Power users can set `PHOTO_SNAIL_OLLAMA_API_KEY`
/// or `PHOTO_SNAIL_OPENAI_API_KEY` to avoid persisting the key; those env
/// vars take precedence at runtime via `withEnvOverrides()`.
///
/// Missing file → `Settings.default` (today's hardcoded behavior). Atomic write
/// via temp-file + rename so a crash mid-save can't leave a partial file.
///
/// Schema versions:
///  - v1 (shipped through v0.1.2): `ollama` connection only.
///  - v2 (v0.1.3): adds `apiProvider` + `openai` connection. Old v1 files
///    decode cleanly with `apiProvider` defaulting to `.ollama` and a default
///    `openai` block, preserving pre-upgrade behavior.
///  - v3 (v0.1.4): adds `modelConfigs` dict keyed by short-family so each
///    model keeps its own prompt, sentinel version, and prompt language.
///    The top-level `customPrompt` / `promptLanguage` / `sentinel` fields
///    are still emitted on save for forward-compat with older readers, but
///    on load `modelConfigs` (when present) is authoritative.
public struct Settings: Codable, Sendable {
    public var version: Int
    public var model: String
    /// Which LLM backend to use. Defaults to `.ollama` to preserve the
    /// privacy-first default. `.openaiCompatible` is for **locally-hosted**
    /// OpenAI-compatible servers (mlx-vlm, LM Studio, vLLM, …).
    public var apiProvider: LLMProvider
    public var ollama: OllamaConnection
    public var openai: OpenAIConnection
    public var appLanguage: String?
    /// When true, the GUI auto-starts processing the queue when the Mac
    /// locks (screen lock / screensaver start) and auto-pauses when it
    /// unlocks. Defaults to false — opt-in feature for desktop users who
    /// leave the machine running for weeks.
    public var autoStartWhenLocked: Bool

    /// Per-family configuration. Keyed by `Sentinel.shortFamily(of: model)`.
    /// The entry matching the current model's family is the "active" config;
    /// other entries are preserved so switching back to a previous model
    /// restores its prompt, sentinel version, and prompt language.
    public var modelConfigs: [String: ModelConfig]

    // MARK: - Derived / active values (read-through to modelConfigs)

    /// Short-family key for the currently-active model.
    public var activeFamily: String {
        Sentinel.shortFamily(of: model)
    }

    /// The active model's configuration. Returns an empty default if no
    /// entry exists yet (fresh install or a brand-new model the user just
    /// picked).
    public var activeConfig: ModelConfig {
        get { modelConfigs[activeFamily] ?? ModelConfig() }
        set { modelConfigs[activeFamily] = newValue }
    }

    /// User-edited prompt for the active model, or `nil` to use the default.
    public var customPrompt: String? {
        get { activeConfig.customPrompt }
        set {
            var cfg = activeConfig
            cfg.customPrompt = newValue
            activeConfig = cfg
        }
    }

    /// Prompt language code for the active model.
    public var promptLanguage: String? {
        get { activeConfig.promptLanguage }
        set {
            var cfg = activeConfig
            cfg.promptLanguage = newValue
            activeConfig = cfg
        }
    }

    /// The sentinel marker used for write-back and bootstrap search for the
    /// active model. Derived from the family + version counter unless the
    /// user has pinned a `customSentinel`.
    public var sentinel: String {
        get {
            let cfg = activeConfig
            if let custom = cfg.customSentinel, !custom.isEmpty {
                return custom
            }
            return Sentinel.make(family: activeFamily, version: cfg.sentinelVersion)
        }
        set {
            var cfg = activeConfig
            // If the new value is the canonical `ai:<activeFamily>-v<N>` form,
            // store only the version and clear any custom pin. Otherwise
            // preserve it verbatim as a custom sentinel.
            if let ver = Sentinel.version(ofSentinel: newValue),
               Sentinel.family(ofSentinel: newValue) == activeFamily {
                cfg.sentinelVersion = ver
                cfg.customSentinel = nil
            } else {
                cfg.customSentinel = newValue
            }
            activeConfig = cfg
        }
    }

    public init(version: Int = 3,
                model: String = "gemma4:31b",
                apiProvider: LLMProvider = .ollama,
                ollama: OllamaConnection = .default,
                openai: OpenAIConnection = .default,
                appLanguage: String? = nil,
                autoStartWhenLocked: Bool = false,
                modelConfigs: [String: ModelConfig] = [:]) {
        self.version = version
        self.model = model
        self.apiProvider = apiProvider
        self.ollama = ollama
        self.openai = openai
        self.appLanguage = appLanguage
        self.autoStartWhenLocked = autoStartWhenLocked
        self.modelConfigs = modelConfigs
    }

    // MARK: - Codable

    // Custom Codable so:
    //  - older settings.json files (no modelConfigs) migrate on load.
    //  - on save we ALSO emit the top-level `customPrompt`/`promptLanguage`/
    //    `sentinel` fields so an older build reading the file still picks up
    //    the active config.
    private enum CodingKeys: String, CodingKey {
        case version, model, sentinel, apiProvider, ollama, openai, customPrompt
        case appLanguage, promptLanguage, autoStartWhenLocked, modelConfigs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gemma4:31b"
        self.apiProvider = try c.decodeIfPresent(LLMProvider.self, forKey: .apiProvider) ?? .ollama
        self.ollama = try c.decodeIfPresent(OllamaConnection.self, forKey: .ollama) ?? .default
        self.openai = try c.decodeIfPresent(OpenAIConnection.self, forKey: .openai) ?? .default
        self.appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage)
        self.autoStartWhenLocked = try c.decodeIfPresent(Bool.self, forKey: .autoStartWhenLocked) ?? false

        // v3 modelConfigs dict. If present, it's authoritative.
        if let configs = try c.decodeIfPresent([String: ModelConfig].self, forKey: .modelConfigs) {
            self.modelConfigs = configs
        } else {
            // Migration v1/v2 → v3: seed a single ModelConfig entry for the
            // active family using the old top-level fields.
            let legacyPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt)
            let legacyLanguage = try c.decodeIfPresent(String.self, forKey: .promptLanguage)
            let legacySentinel = try c.decodeIfPresent(String.self, forKey: .sentinel)
                ?? "ai:gemma4-v1"

            // Prefer the short family as the dictionary key so future lookups
            // land on the expected entry. If the legacy sentinel's family
            // differs from the short form (e.g. a pre-existing long-form
            // sentinel), pin it as `customSentinel` to preserve byte-level
            // compatibility with what's already written into Photos.app.
            let shortFam = Sentinel.shortFamily(of: model)
            let legacyFam = Sentinel.family(ofSentinel: legacySentinel)
            let legacyVersion = Sentinel.version(ofSentinel: legacySentinel) ?? 1

            let cfg: ModelConfig
            if let lf = legacyFam, lf == shortFam {
                cfg = ModelConfig(customPrompt: legacyPrompt,
                                  sentinelVersion: legacyVersion,
                                  customSentinel: nil,
                                  promptLanguage: legacyLanguage)
            } else {
                cfg = ModelConfig(customPrompt: legacyPrompt,
                                  sentinelVersion: legacyVersion,
                                  customSentinel: legacySentinel,
                                  promptLanguage: legacyLanguage)
            }
            self.modelConfigs = [shortFam: cfg]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(model, forKey: .model)
        try c.encode(apiProvider, forKey: .apiProvider)
        try c.encode(ollama, forKey: .ollama)
        try c.encode(openai, forKey: .openai)
        try c.encodeIfPresent(appLanguage, forKey: .appLanguage)
        try c.encode(autoStartWhenLocked, forKey: .autoStartWhenLocked)
        try c.encode(modelConfigs, forKey: .modelConfigs)

        // Mirror the active config to top-level fields for forward-compat
        // with readers that don't understand modelConfigs yet.
        try c.encode(sentinel, forKey: .sentinel)
        try c.encodeIfPresent(customPrompt, forKey: .customPrompt)
        try c.encodeIfPresent(promptLanguage, forKey: .promptLanguage)
    }

    public static let `default` = Settings()

    /// `~/Library/Application Support/photo-snail/settings.json`
    public static var defaultPath: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("photo-snail", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Load settings from disk. Returns `.default` if the file is missing.
    /// Throws on JSON decode errors (corrupt file) — caller should surface clearly.
    public static func load(from path: URL = defaultPath) throws -> Settings {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            return .default
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    /// Save settings atomically to disk with `0600` permissions.
    ///
    /// The temp file is chmod-ed BEFORE the rename so the API key (if present)
    /// is never world-readable on disk, even momentarily. `Data.write(.atomic)`
    /// would create the file with umask defaults (typically 0644) before we
    /// could chmod it — that race is small but real.
    public func save(to path: URL = defaultPath) throws {
        let fm = FileManager.default
        let parent = path.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        let tempName = ".settings.json.tmp-\(UUID().uuidString.prefix(8))"
        let temp = parent.appendingPathComponent(String(tempName))
        try data.write(to: temp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)

        if fm.fileExists(atPath: path.path) {
            _ = try fm.replaceItemAt(path, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: path)
        }
    }

    /// Apply env-var overrides for API keys at runtime. Returns a copy that
    /// must NOT be written back to disk — the env vars are intentionally
    /// non-persisted so power users can scope them to a single run.
    ///
    ///  - `PHOTO_SNAIL_OLLAMA_API_KEY` → `ollama.apiKey`
    ///  - `PHOTO_SNAIL_OPENAI_API_KEY` → `openai.apiKey`
    public func withEnvOverrides() -> Settings {
        var copy = self
        let env = ProcessInfo.processInfo.environment
        if let key = env["PHOTO_SNAIL_OLLAMA_API_KEY"], !key.isEmpty {
            copy.ollama.apiKey = key
        }
        if let key = env["PHOTO_SNAIL_OPENAI_API_KEY"], !key.isEmpty {
            copy.openai.apiKey = key
        }
        return copy
    }

    /// Build the right `LLMClient` for the currently-selected provider using
    /// this settings object's connection blocks. Used by CLI and GUI to get
    /// a ready-to-use client without branching on the enum at each call site.
    public func makeLLMClient(imageOptions: OllamaImageOptions = OllamaImageOptions()) -> any LLMClient {
        switch apiProvider {
        case .ollama:
            return OllamaClient(connection: ollama, imageOptions: imageOptions)
        case .openaiCompatible:
            let openaiOpts = OpenAIImageOptions(
                downsize: imageOptions.downsize,
                maxPixelSize: imageOptions.maxPixelSize,
                jpegQuality: imageOptions.jpegQuality
            )
            return OpenAIClient(connection: openai, imageOptions: openaiOpts)
        }
    }
}
