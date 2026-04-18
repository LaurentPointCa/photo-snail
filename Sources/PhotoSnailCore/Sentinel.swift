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
        return sanitize(beforeColon)
    }

    /// Like `family(of:)` but produces a compact family name for verbose
    /// OpenAI-compatible model IDs such as `mlx-community/Qwen3.6-35B-A3B-4bit`.
    /// Strips:
    ///   - organization prefix (everything up to and including the last `/`)
    ///   - quantization suffixes (`-4bit`, `-q4_K_M`, `-gptq`, `-mlx`, `-bf16`, …)
    ///   - parameter-size suffixes (`-35b`, `-7b`, `-1.5b`, `-a3b` activation size)
    ///   - instruction-tuning suffixes (`-instruct`, `-chat`, `-base`, `-it`)
    /// Repeats until nothing matches, then sanitizes the remainder the same
    /// way `family(of:)` does. Examples:
    ///
    ///   gemma4:31b                             → `gemma4`
    ///   mlx-community/Qwen3.6-35B-A3B-4bit     → `qwen3-6`
    ///   TheBloke/Llama-3.2-7B-Instruct-GPTQ    → `llama-3-2`
    ///   mlx-community/Qwen2-VL-7B-Instruct     → `qwen2-vl`
    ///
    /// Used ONLY in the `propose(...)` path — existing persisted sentinels keep
    /// parsing through `family(of:)`/`family(ofSentinel:)` so we never rewrite
    /// sentinels we've already written into Photos.app metadata.
    public static func shortFamily(of model: String) -> String {
        // Ollama tags (`family:tag`) are already compact — defer to family(of:).
        if model.contains(":") {
            return family(of: model)
        }

        var s = model
        // Strip org prefix: `mlx-community/...` → `...`
        if let slash = s.lastIndex(of: "/") {
            s = String(s[s.index(after: slash)...])
        }

        // Suffixes to strip iteratively. Order within the array doesn't matter
        // because we loop until no pattern matches. Case-insensitive; anchored
        // at end-of-string so only trailing segments go.
        let suffixPatterns: [String] = [
            "(?i)-(2bit|3bit|4bit|5bit|6bit|8bit|16bit)$",
            "(?i)-q[0-9]+(_[a-z0-9]+)*$",
            "(?i)-(fp16|bf16|fp32|fp8|int4|int8)$",
            "(?i)-(gptq|awq|gguf|ggml|mlx)$",
            "(?i)-(instruct|chat|base|it)$",
            "(?i)-a?[0-9]+(\\.[0-9]+)?b$",
        ]

        var changed = true
        while changed {
            changed = false
            for pattern in suffixPatterns {
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(s.startIndex..., in: s)
                if let m = re.firstMatch(in: s, options: [], range: range), m.range.length > 0,
                   let swiftRange = Range(m.range, in: s) {
                    s.removeSubrange(swiftRange)
                    changed = true
                }
            }
        }

        return sanitize(s)
    }

    /// Shared sanitizer: lowercase, non-alphanumerics → `-`, collapse runs,
    /// trim leading/trailing dashes. Empty result becomes `unknown`.
    private static func sanitize(_ input: String) -> String {
        let lowered = input.lowercased()
        var out = ""
        for c in lowered {
            if c.isLetter || c.isNumber {
                out.append(c)
            } else {
                out.append("-")
            }
        }
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
    ///
    /// Uses `shortFamily(of:)` for the proposed name so verbose OpenAI-compatible
    /// IDs don't produce unwieldy sentinels. Both the short and long forms are
    /// accepted as "same family" for the no-change check, so users who already
    /// have a long-form sentinel persisted don't get prompted to migrate.
    public static func propose(forModel model: String, currentSentinel: String) -> String? {
        let newFamilyShort = shortFamily(of: model)
        let newFamilyLong = family(of: model)
        if let currentFamily = family(ofSentinel: currentSentinel) {
            if currentFamily == newFamilyShort || currentFamily == newFamilyLong {
                return nil
            }
        }
        return make(family: newFamilyShort, version: 1)
    }

    /// Return `true` if `text` contains at least one PhotoSnail-shaped sentinel
    /// (`ai:<family>-v<N>`), regardless of which model family wrote it. Used by
    /// the write-back path to decide whether an existing description belongs to
    /// us (overwrite freely) or to the user (preserve, append ours after a
    /// separator). The pattern mirrors `family(of:)`'s sanitization rule
    /// (alphanumeric runs separated by single dashes) so every sentinel we
    /// could have written matches.
    public static func containsAnySentinel(_ text: String) -> Bool {
        let pattern = "ai:[a-z0-9]+(-[a-z0-9]+)*-v[0-9]+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}
