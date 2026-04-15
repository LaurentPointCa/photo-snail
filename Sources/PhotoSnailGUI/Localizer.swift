import SwiftUI

/// Runtime language switching for the PhotoSnail GUI.
///
/// SwiftUI's built-in localization system follows the system locale and requires
/// an app restart. This provides runtime switching: views call `loc.t("key")`
/// and re-render automatically when `language` changes (because `Localizer` is
/// `@Observable`).
///
/// Persistence: `language` is saved to `UserDefaults` under `"photo-snail.language"`.
/// App language and prompt language can differ (English UI, French descriptions).
@Observable
@MainActor
final class Localizer {
    static let shared = Localizer()

    enum Language: String, CaseIterable, Identifiable, Codable, Sendable {
        case en, fr, es, de, pt, ja, zhHans, ko

        var id: String { rawValue }

        /// Name in the language itself (for the Language menu).
        var nativeName: String {
            switch self {
            case .en:     return "English"
            case .fr:     return "Francais"
            case .es:     return "Espanol"
            case .de:     return "Deutsch"
            case .pt:     return "Portugues"
            case .ja:     return "Japanese"
            case .zhHans: return "Chinese (Simplified)"
            case .ko:     return "Korean"
            }
        }

        /// ISO 639-1 code (or BCP-47 for zh-Hans).
        var code: String { rawValue }

        /// English name for use in prompts (e.g. "Translate to French").
        var englishName: String {
            switch self {
            case .en:     return "English"
            case .fr:     return "French"
            case .es:     return "Spanish"
            case .de:     return "German"
            case .pt:     return "Portuguese"
            case .ja:     return "Japanese"
            case .zhHans: return "Chinese (Simplified)"
            case .ko:     return "Korean"
            }
        }
    }

    var language: Language = .en {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "photo-snail.language")
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "photo-snail.language"),
           let lang = Language(rawValue: raw) {
            self.language = lang
        }
    }

    /// Look up a translated string. Falls back to English if the key is missing
    /// in the current language.
    func t(_ key: String) -> String {
        if let dict = Strings.translations[language], let val = dict[key] {
            return val
        }
        return Strings.translations[.en]?[key] ?? key
    }

    /// English name of a language given its code string. Used by the translation
    /// pipeline prompt (which runs off the main actor and doesn't hold a Localizer).
    /// Marked nonisolated because `Language.englishName` is a pure value lookup
    /// with no mutable state dependency.
    nonisolated static func languageName(for code: String) -> String {
        if let lang = Language(rawValue: code) {
            return lang.englishName
        }
        return code
    }

    /// Pre-translated prompt templates for each language.
    static func promptTemplate(for language: Language) -> String {
        return Strings.promptTemplates[language] ?? Strings.promptTemplates[.en]!
    }

    /// Pending language change target, set by the Language menu in the app commands.
    /// The LibraryWindow observes this and presents the LanguageChangeSheet.
    var pendingLanguageChange: Language? = nil
}
