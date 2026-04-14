import Foundation

/// Helpers for deriving sentinel markers from Ollama model names.
///
/// The sentinel format is `ai:<family>-v<N>`. The `family` is the part of the
/// Ollama model name before the `:` (the tag), lowercased and sanitized so any
/// non-alphanumeric character becomes `-`. Examples:
///
///   gemma4:31b        → family `gemma4`        → `ai:gemma4-v1`
///   gemma4:latest     → family `gemma4`        → same family as above
///   llama3.2:latest   → family `llama3-2`      → `ai:llama3-2-v1`
///   llava:13b         → family `llava`         → `ai:llava-v1`
///   mistral-small:3b  → family `mistral-small` → `ai:mistral-small-v1`
///
/// Switching between two model tags within the same family (e.g. `gemma4:31b`
/// → `gemma4:latest`) does NOT propose a new sentinel, because the model family
/// is what determines whether captions are comparable. Switching to a different
/// family does propose `<newfamily>-v1`, leaving the version bump (`v2`, `v3`...)
/// as an explicit user choice.
public enum Sentinel {

    /// Extract the family token from an Ollama model name.
    public static func family(of model: String) -> String {
        let beforeColon = model.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? model
        let lowered = beforeColon.lowercased()
        var out = ""
        for c in lowered {
            if c.isLetter || c.isNumber {
                out.append(c)
            } else {
                out.append("-")
            }
        }
        // Collapse runs of dashes; trim leading/trailing dashes.
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "unknown" : out
    }

    /// Parse the family token out of an existing sentinel like `ai:gemma4-v1`.
    /// Returns nil if the sentinel doesn't match the expected `ai:<family>-v<N>` shape.
    public static func family(ofSentinel sentinel: String) -> String? {
        guard sentinel.hasPrefix("ai:") else { return nil }
        let body = String(sentinel.dropFirst(3))   // drop "ai:"
        // Split on the LAST "-v" so families containing dashes (e.g. mistral-small) survive.
        guard let vRange = body.range(of: "-v", options: .backwards) else { return nil }
        let familyPart = String(body[..<vRange.lowerBound])
        let versionPart = String(body[vRange.upperBound...])
        guard !familyPart.isEmpty, Int(versionPart) != nil else { return nil }
        return familyPart
    }

    /// Build a sentinel for a given family at a given version.
    public static func make(family: String, version: Int = 1) -> String {
        return "ai:\(family)-v\(version)"
    }

    /// Extract the integer version from an existing sentinel like `ai:gemma4-v1`.
    /// Returns nil if the sentinel doesn't match the expected `ai:<family>-v<N>` shape.
    public static func version(ofSentinel sentinel: String) -> Int? {
        guard sentinel.hasPrefix("ai:") else { return nil }
        let body = String(sentinel.dropFirst(3))
        guard let vRange = body.range(of: "-v", options: .backwards) else { return nil }
        let familyPart = String(body[..<vRange.lowerBound])
        let versionPart = String(body[vRange.upperBound...])
        guard !familyPart.isEmpty else { return nil }
        return Int(versionPart)
    }

    /// Bump the version of an existing sentinel: `ai:gemma4-v1` → `ai:gemma4-v2`.
    /// Returns nil if the sentinel is malformed.
    public static func bumpVersion(currentSentinel: String) -> String? {
        guard let fam = family(ofSentinel: currentSentinel),
              let ver = version(ofSentinel: currentSentinel) else { return nil }
        return make(family: fam, version: ver + 1)
    }

    /// Propose a new sentinel for `model` if its family differs from `currentSentinel`'s.
    /// Returns `nil` when the family is unchanged (caller should keep `currentSentinel`).
    /// If `currentSentinel` is malformed or empty, returns a fresh `ai:<family>-v1`.
    public static func propose(forModel model: String, currentSentinel: String) -> String? {
        let newFamily = family(of: model)
        if let currentFamily = family(ofSentinel: currentSentinel) {
            if currentFamily == newFamily {
                return nil
            }
        }
        return make(family: newFamily, version: 1)
    }
}
