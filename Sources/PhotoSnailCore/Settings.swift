import Foundation

/// Persistent user settings shared by the CLI and GUI.
///
/// Stored as JSON at `~/Library/Application Support/photo-snail/settings.json`
/// with `0600` permissions. The API key is plain text on disk — the tradeoff is
/// documented in CLAUDE.md. Power users can set `PHOTO_SNAIL_OLLAMA_API_KEY`
/// to avoid persisting the key entirely; that env var takes precedence at runtime.
///
/// Missing file → `Settings.default` (today's hardcoded behavior). Atomic write
/// via temp-file + rename so a crash mid-save can't leave a partial file.
public struct Settings: Codable, Sendable {
    public var version: Int
    public var model: String
    public var sentinel: String
    public var ollama: OllamaConnection
    public var customPrompt: String?
    public var appLanguage: String?
    public var promptLanguage: String?
    /// When true, the GUI auto-starts processing the queue when the Mac
    /// locks (screen lock / screensaver start) and auto-pauses when it
    /// unlocks. Defaults to false — opt-in feature for desktop users who
    /// leave the machine running for weeks.
    public var autoStartWhenLocked: Bool

    public init(version: Int = 1,
                model: String = "gemma4:31b",
                sentinel: String = "ai:gemma4-v1",
                ollama: OllamaConnection = .default,
                customPrompt: String? = nil,
                appLanguage: String? = nil,
                promptLanguage: String? = nil,
                autoStartWhenLocked: Bool = false) {
        self.version = version
        self.model = model
        self.sentinel = sentinel
        self.ollama = ollama
        self.customPrompt = customPrompt
        self.appLanguage = appLanguage
        self.promptLanguage = promptLanguage
        self.autoStartWhenLocked = autoStartWhenLocked
    }

    // Custom Codable so older settings.json files (without
    // autoStartWhenLocked) decode cleanly with the default `false`.
    private enum CodingKeys: String, CodingKey {
        case version, model, sentinel, ollama, customPrompt
        case appLanguage, promptLanguage, autoStartWhenLocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gemma4:31b"
        self.sentinel = try c.decodeIfPresent(String.self, forKey: .sentinel) ?? "ai:gemma4-v1"
        self.ollama = try c.decodeIfPresent(OllamaConnection.self, forKey: .ollama) ?? .default
        self.customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt)
        self.appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage)
        self.promptLanguage = try c.decodeIfPresent(String.self, forKey: .promptLanguage)
        self.autoStartWhenLocked = try c.decodeIfPresent(Bool.self, forKey: .autoStartWhenLocked) ?? false
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

    /// Apply the `PHOTO_SNAIL_OLLAMA_API_KEY` env var override (if set) to the
    /// in-memory `ollama.apiKey` without persisting it. Returns a copy.
    /// Use this at runtime, AFTER `load()` and BEFORE constructing `OllamaClient`,
    /// so the env var takes precedence over the on-disk value but never gets
    /// written back via `save()`.
    public func withEnvOverrides() -> Settings {
        var copy = self
        if let envKey = ProcessInfo.processInfo.environment["PHOTO_SNAIL_OLLAMA_API_KEY"], !envKey.isEmpty {
            copy.ollama.apiKey = envKey
        }
        return copy
    }
}
