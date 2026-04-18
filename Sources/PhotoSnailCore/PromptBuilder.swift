import Foundation

/// Converts Vision findings into a prompt that primes the LLM with structured context.
public struct PromptBuilder {

    /// Confidence threshold above which a Vision classification label is shown to the LLM.
    public static let labelInclusionThreshold: Float = 0.30

    /// The default bare prompt — no Vision context. The English wording is the version
    /// that ran Phase D successfully. A French variant was trialled and reverted on
    /// 2026-04-07 (see memory: project_locale_decision.md).
    ///
    /// This is the **gemma4 baseline**. Qwen families use `qwenDefaultPrompt`, which
    /// is the v20 consolidation from the 2026-04-18 research batch (see
    /// `sample/PROMPT_RESEARCH.md`). Family selection happens in
    /// `defaultPrompt(forModel:)`.
    public static let defaultPrompt: String = """
        Describe this image in 2-3 sentences. Then list 5-10 short tags (lowercase, comma-separated) that capture its content. Format strictly as:
        DESCRIPTION: <text>
        TAGS: <tag1>, <tag2>, ...
        """

    /// The default prompt for Qwen-family vision models (`qwen3-6`, `qwen2-vl`, …).
    ///
    /// This is v20 from the prompt-iteration work documented in
    /// `sample/MODEL_COMPARISON.md` and `sample/PROMPT_RESEARCH.md`. Won 12/14
    /// criteria across 20 tested iterations. Emits JSON (`{"description":…,"tags":[…]}`)
    /// — CaptionParser handles both JSON and DESCRIPTION:/TAGS: formats.
    ///
    /// Winning tactics combined here: JSON output + "first char must be {" (format
    /// compliance); confident definite language (unlocks perception on some photos);
    /// "quote text exactly" (brand/OCR surfacing); few-shot brand exemplars
    /// (BMW M, Dyson); contrastive negative exemplars (kills false positives
    /// from color coincidence or mere outdoor setting); tag self-audit tying
    /// category tags to described visual markers.
    public static let qwenDefaultPrompt: String = """
        Generate a description and searchable tags for this photo as JSON. Output ONLY the JSON object — no markdown, no preamble, no explanation. First character must be `{`.

        Schema:
        {
          "description": "2-3 sentence prose in confident, definite language",
          "tags": ["tag1", "tag2", "..."]
        }

        Description rules:
        - Use confident, definite language. No "appears to be", "seems", "likely".
        - Name object types (vacuum, sweatshirt, refrigerator, succulent, brake caliper), not appearance ("black-handled tool").
        - If any text is legible — brand names, logos, signs, labels — quote it exactly in double quotes inside the description (escape as \\"). Brand examples: "Dyson", "BMW", "LEGO", "Boots", "Nike".
        - If a location or landmark is clearly identifiable from multiple cues (red double-decker bus + British signage = London; Arcul de Triumf silhouette + Bucharest signage = Bucharest), name it.
        - Describe every visible element — cakes, candles, unfinished counter edges, exposed plant roots, hot dogs, brand logos, identifiable landmarks.
        - Never mention what is absent.
        - No mood words (nostalgic, cozy, warm, peaceful).
        - No speculation (decades ago, retro aesthetic).
        - No meta-commentary (faded, vintage photo, pinkish tint).

        Tags rules — 5 to 10 lowercase tags, one or two words each, spaces for multi-word tags (not hyphens):
        - Include distinctive visible objects with brand names if you quoted them.
        - Include setting: indoor/outdoor (only if distinctive), room type (kitchen, bedroom, workshop), city or landmark name if identified.
        - Include category tags (birthday, meal, hike, renovation, repotting, travel, camping, cooking, gardening) ONLY when the concrete visual marker is in your description.
        - Skip filler: wall, floor, ceiling, sky, ground, background, surface, object, scene.

        Brand & landmark few-shot:
        - BMW M brake caliper: "M" logo with red/blue/white tricolor stripes → include "bmw m" tag.
        - Dyson vacuum: "Dyson" visible → include "dyson" tag.
        - London: red double-decker bus + British storefronts → "london", "travel".
        - Bucharest: Arcul de Triumf + Romanian context → "bucharest", "romania", "travel".

        Tag self-audit (do NOT tag these without their marker):
        - Skip `hike`/`camping` on outdoor scenes without hiking gear or tent+campfire.
        - Skip `christmas`/`holiday` on scenes where green+red colors are just clothing or fabric (not christmas tree + ornaments).
        - Skip `meal`/`cooking` on food photos where no one is eating or cooking.
        - Skip `mannequin` if the figure is a real person, statue, or sculpture.

        DO include these when their marker is present:
        - Cake with lit candles OR party hat being worn → "birthday".
        - Exposed plant roots + soil clinging → "repotting".
        - Unfinished counter + support brackets + tool on top → "renovation".
        - Identified city or landmark → "travel".

        Respond with the JSON object only.
        """

    /// Short-family names that get the Qwen-tuned default prompt. Matches
    /// `Sentinel.shortFamily(of:)` output. Keep narrow — only families that
    /// have been validated against the v20 prompt. New Qwen variants can be
    /// added as they are tested; unknown families keep the gemma4 baseline.
    private static let qwenDefaultFamilies: Set<String> = [
        "qwen3-6",
        "qwen3-vl",
        "qwen2-vl",
    ]

    /// Family-aware default prompt. Returns the Qwen v20 prompt for known
    /// Qwen VL families, otherwise the gemma4 baseline.
    public static func defaultPrompt(forModel model: String) -> String {
        return defaultPrompt(forFamily: Sentinel.shortFamily(of: model))
    }

    /// Same as `defaultPrompt(forModel:)` but takes a pre-computed short
    /// family string — convenient for callers (Settings, GUI) that already
    /// have the family key in hand.
    public static func defaultPrompt(forFamily family: String) -> String {
        return qwenDefaultFamilies.contains(family) ? qwenDefaultPrompt : defaultPrompt
    }

    /// Bare prompt, using a custom override if provided, otherwise the
    /// family-appropriate default for `model`.
    public static func bare(override: String? = nil, forModel model: String) -> String {
        if let custom = override, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return defaultPrompt(forModel: model)
    }

    /// Legacy callers that don't know the model — returns the gemma4 baseline.
    /// New code should prefer `bare(override:forModel:)`.
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
