import Foundation

/// Converts Vision findings into a prompt that primes the LLM with structured context.
public struct PromptBuilder {

    /// Confidence threshold above which a Vision classification label is shown to the LLM.
    public static let labelInclusionThreshold: Float = 0.30

    /// The default bare prompt — no Vision context. The English wording is the version
    /// that ran Phase D successfully. A French variant was trialled and reverted on
    /// 2026-04-07 (see memory: project_locale_decision.md).
    public static let defaultPrompt: String = """
        Describe this image in 2-3 sentences. Then list 5-10 short tags (lowercase, comma-separated) that capture its content. Format strictly as:
        DESCRIPTION: <text>
        TAGS: <tag1>, <tag2>, ...
        """

    /// Bare prompt, using a custom override if provided.
    public static func bare(override: String? = nil) -> String {
        if let custom = override, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return defaultPrompt
    }

    /// Build a prompt that injects Vision findings as supporting context, then asks for description + tags
    /// in the strict format the parser expects.
    ///
    /// Wording goal: position the LLM as the primary observer and Vision as a hint sheet.
    /// Earlier versions said "use them as ground truth", which biased gemma4:31b away from
    /// describing what it actually saw — see project_hybrid_prompt_bias_finding.md.
    public static func build(findings: VisionFindings) -> String {
        var lines: [String] = []
        lines.append("Look carefully at this personal photo and describe what you actually see in it. A separate automated pre-pass has surfaced a few signals that may help you confirm details — they are listed below for reference, but they are NOT the description. Animal counts, face counts, and OCR text are reliable. The scene labels are coarse and often generic. Rely primarily on your own observation of the image; use the signals only to confirm specific details (especially text or brand names visible in the OCR).")
        lines.append("")

        // Animal counts (very high signal — Vision is reliable here)
        if !findings.animals.isEmpty {
            let summary = animalSummary(findings.animals)
            lines.append("ANIMALS DETECTED: \(summary)")
        } else {
            lines.append("ANIMALS DETECTED: none")
        }

        // Face counts
        if findings.faces.isEmpty {
            lines.append("FACES DETECTED: 0")
        } else {
            lines.append("FACES DETECTED: \(findings.faces.count)")
        }

        // Top classification labels (filtered by threshold)
        let topLabels = findings.classifications
            .filter { $0.confidence >= labelInclusionThreshold }
            .prefix(12)
            .map { "\($0.identifier) (\(String(format: "%.2f", $0.confidence)))" }
            .joined(separator: ", ")
        if !topLabels.isEmpty {
            lines.append("VISION SCENE LABELS: \(topLabels)")
        } else {
            lines.append("VISION SCENE LABELS: (none above threshold)")
        }

        // OCR text — high-value, especially for branded/labelled subjects
        if findings.ocrText.isEmpty {
            lines.append("OCR TEXT: (none)")
        } else {
            // Dedupe while preserving order; cap length
            var seen = Set<String>()
            var dedup: [String] = []
            for s in findings.ocrText {
                let lower = s.lowercased()
                if !seen.contains(lower) {
                    seen.insert(lower)
                    dedup.append(s)
                }
            }
            let joined = dedup.joined(separator: " | ")
            let truncated = joined.count > 400 ? String(joined.prefix(400)) + "…" : joined
            lines.append("OCR TEXT: \"\(truncated)\"")
        }

        lines.append("")
        lines.append("Now write a 2–3 sentence DESCRIPTION of the photo. Then list 5–10 short, specific TAGS (lowercase, comma-separated) capturing the subject, setting, objects, and any visible brand or text. Prefer concrete nouns over generic categories. If the OCR text contains a brand name, include it as a tag. Format strictly as:")
        lines.append("DESCRIPTION: <text>")
        lines.append("TAGS: <tag1>, <tag2>, ...")

        return lines.joined(separator: "\n")
    }

    private static func animalSummary(_ regions: [DetectedRegion]) -> String {
        // Group by label
        var counts: [String: Int] = [:]
        for r in regions {
            counts[r.label, default: 0] += 1
        }
        let parts = counts
            .sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)\($0.value > 1 ? "s" : "")" }
        return parts.joined(separator: ", ")
    }
}
