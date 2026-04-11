import Foundation

/// Parses the LLM's structured DESCRIPTION/TAGS response.
public struct CaptionParser {

    public struct Parsed {
        public let description: String
        public let tags: [String]
    }

    /// Tolerant parser. Accepts variations like:
    ///   "DESCRIPTION: ..." / "Description: ..." / "**DESCRIPTION:** ..."
    ///   "TAGS: a, b, c" / "Tags: a; b; c"
    public static func parse(_ raw: String) -> Parsed {
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
