import Foundation

/// Parses the LLM's structured response.
///
/// Supports two shapes:
///   1. Colon-header: "DESCRIPTION: ... TAGS: a, b, c" (gemma4 and earlier Qwen prompts).
///   2. JSON object: `{"description": "...", "tags": ["a", "b"]}` (Qwen v20+).
///
/// The JSON path is attempted first when the response's first non-whitespace
/// character looks like a JSON object start. Markdown fences (```json ... ```)
/// and short preambles before the object are tolerated — we locate the first
/// `{` and parse from there. If JSON parsing fails for any reason, we fall
/// through to the colon-header parser.
public struct CaptionParser {

    public struct Parsed {
        public let description: String
        public let tags: [String]
    }

    public static func parse(_ raw: String) -> Parsed {
        if let parsed = parseJSON(raw) {
            return parsed
        }
        return parseColonHeaders(raw)
    }

    // MARK: - JSON path

    private struct JSONShape: Decodable {
        let description: String?
        let tags: [String]?
    }

    /// Try to decode a JSON object with `description` + `tags` out of `raw`.
    /// Returns nil if the response isn't JSON-shaped or decode fails — caller
    /// should then try the colon-header parser.
    static func parseJSON(_ raw: String) -> Parsed? {
        guard let objectData = extractJSONObject(from: raw) else { return nil }
        guard let shape = try? JSONDecoder().decode(JSONShape.self, from: objectData) else {
            return nil
        }
        let description = (shape.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (shape.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        // If neither field produced content, treat as a parse miss so the
        // caller falls back to the colon-header path.
        if description.isEmpty && tags.isEmpty { return nil }
        return Parsed(description: description, tags: tags)
    }

    /// Locate the outermost `{...}` object in `raw` by brace-balanced scanning.
    /// Tolerates leading/trailing text (markdown fences, "Here's the JSON:"
    /// preamble). Returns the object bytes ready for JSONDecoder, or nil if
    /// no balanced object exists.
    private static func extractJSONObject(from raw: String) -> Data? {
        guard let openIdx = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var endIdx: String.Index? = nil
        for i in raw.indices[openIdx...] {
            let c = raw[i]
            if escape { escape = false; continue }
            if c == "\\" && inString { escape = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { endIdx = i; break }
            }
        }
        guard let end = endIdx else { return nil }
        let slice = String(raw[openIdx...end])
        return slice.data(using: .utf8)
    }

    // MARK: - Colon-header path (legacy)

    /// Tolerant parser. Accepts variations like:
    ///   "DESCRIPTION: ..." / "Description: ..." / "**DESCRIPTION:** ..."
    ///   "TAGS: a, b, c" / "Tags: a; b; c"
    static func parseColonHeaders(_ raw: String) -> Parsed {
        let normalized = raw.replacingOccurrences(of: "**", with: "")
        var description = ""
        var tagsLine = ""

        // Find the description line(s) — text after "DESCRIPTION:" up to "TAGS:" (or EOF)
        if let descRange = normalized.range(of: "DESCRIPTION:", options: [.caseInsensitive]) {
            let afterDesc = normalized[descRange.upperBound...]
            if let tagsRange = afterDesc.range(of: "TAGS:", options: [.caseInsensitive]) {
                description = afterDesc[..<tagsRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                tagsLine = afterDesc[tagsRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                description = afterDesc.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let tagsRange = normalized.range(of: "TAGS:", options: [.caseInsensitive]) {
            // No DESCRIPTION marker; everything before TAGS becomes description
            description = normalized[..<tagsRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            tagsLine = normalized[tagsRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            description = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip trailing junk lines from tagsLine (some models add commentary after the tag list)
        if let firstNewline = tagsLine.firstIndex(of: "\n") {
            tagsLine = String(tagsLine[..<firstNewline])
        }

        // Split tags on , or ;
        let rawTags = tagsLine.split { $0 == "," || $0 == ";" }
        let tags = rawTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        return Parsed(description: description, tags: tags)
    }
}
