import Foundation

/// Which prompting strategy the pipeline uses.
public enum PromptStyle: String, Codable, Sendable {
    /// Bare prompt — no Vision pre-pass at all. Pure LLM. Used as the control / baseline.
    case bare
    /// Side-channel (v3, default): Vision pre-pass runs for OCR rescue and structured
    /// metadata (animal/face counts), but the LLM still receives the bare prompt — Vision
    /// findings are NOT injected into the prompt. This is the recommended mode after the
    /// repeatability test showed the in-prompt hybrid is ~2× slower at generation with no
    /// meaningful quality gain on common subjects. See project_hybrid_prompt_bias_finding.md.
    case sideChannel
    /// Full hybrid: Vision pre-pass runs and findings are injected into the LLM prompt.
    /// Kept for comparison; not the default.
    case hybrid
}

/// Orchestrates the pipeline: optional Vision pre-pass → prompt → Ollama → parse → merge.
public final class Pipeline {

    public let model: String
    public let promptStyle: PromptStyle
    public let visionAnalyzer: VisionAnalyzer
    public let ollama: OllamaClient

    public init(
        model: String = "gemma4:31b",
        promptStyle: PromptStyle = .sideChannel,
        visionAnalyzer: VisionAnalyzer = VisionAnalyzer(),
        ollama: OllamaClient = OllamaClient()
    ) {
        self.model = model
        self.promptStyle = promptStyle
        self.visionAnalyzer = visionAnalyzer
        self.ollama = ollama
    }

    /// Process an image from a file path (CLI entry point).
    public func process(imagePath: String) async throws -> PipelineResult {
        guard let (_, _, w, h) = VisionAnalyzer.loadCGImageWithOrientation(imagePath) else {
            throw PhotoSnailError.imageLoadFailed(imagePath)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        return try await processCore(imageData: data, identifier: imagePath, pixelWidth: w, pixelHeight: h)
    }

    /// Process an image from in-memory data (PhotoKit entry point).
    /// `identifier` is stored in `PipelineResult.imagePath` — typically `PHAsset.localIdentifier`.
    public func process(imageData: Data, identifier: String) async throws -> PipelineResult {
        guard let (_, _, w, h) = VisionAnalyzer.loadCGImageWithOrientation(data: imageData) else {
            throw PhotoSnailError.imageLoadFailed(identifier)
        }
        return try await processCore(imageData: imageData, identifier: identifier, pixelWidth: w, pixelHeight: h)
    }

    /// Shared pipeline orchestration: Vision pre-pass → prompt → Ollama → parse → merge.
    private func processCore(imageData: Data, identifier: String,
                             pixelWidth w: Int, pixelHeight h: Int) async throws -> PipelineResult {
        let pipelineStart = Date()

        // 1. Vision pre-pass (skipped only in pure bare mode)
        let findings: VisionFindings
        let prompt: String
        switch promptStyle {
        case .bare:
            findings = .empty
            prompt = PromptBuilder.bare()
        case .sideChannel:
            findings = try visionAnalyzer.analyze(imageData: imageData)
            prompt = PromptBuilder.bare()
        case .hybrid:
            findings = try visionAnalyzer.analyze(imageData: imageData)
            prompt = PromptBuilder.build(findings: findings)
        }

        // 2. Caption via Ollama (image is downsized inside OllamaClient by default)
        let caption = try await ollama.generateCaption(
            model: model, prompt: prompt, imageData: imageData,
            sourcePixelWidth: w, sourcePixelHeight: h
        )

        // 3. Merge tags (LLM tags + LLM-confirmed OCR brand rescue)
        let merged = mergeTags(modelTags: caption.tags, ocr: findings.ocrText, llmRawResponse: caption.rawResponse)

        let total = Date().timeIntervalSince(pipelineStart)
        return PipelineResult(
            imagePath: identifier,
            pixelWidth: w,
            pixelHeight: h,
            vision: findings,
            prompt: prompt,
            caption: caption,
            mergedTags: merged,
            totalElapsedSeconds: total
        )
    }

    /// Format the description payload for Photos.app write-back.
    /// Output: `<description>. Tags: tag1, tag2, ..., <sentinel>`
    public static func formatDescription(description: String, tags: [String], sentinel: String = "ai:gemma4-v1") -> String {
        var allTags = tags
        if !allTags.contains(sentinel) {
            allTags.append(sentinel)
        }
        return "\(description). Tags: \(allTags.joined(separator: ", "))"
    }

    /// Merge strategy (v3):
    /// 1. LLM tags are authoritative — they go in first, in order.
    /// 2. Vision classification labels are NOT merged. They're already passed to the LLM as
    ///    prompt context (when in hybrid mode); the LLM produces better-shaped tags than the
    ///    raw classifier vocabulary (which leaks generic terms like "structure", "machine").
    /// 3. OCR tokens are rescued ONLY when (a) the LLM's free-text response also mentions
    ///    them (cross-check on garbled OCR), AND (b) the token is not a common English/French
    ///    function word (the stop-list below). The length window (4–20) keeps short brand
    ///    names like Sony/Lego/Audi while filtering single letters and OCR garbage strings.
    public func mergeTags(modelTags: [String], ocr: [String], llmRawResponse: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func add(_ raw: String) {
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
            guard !cleaned.isEmpty else { return }
            if !seen.contains(cleaned) {
                seen.insert(cleaned)
                out.append(cleaned)
            }
        }

        // 1. LLM tags first (preserve order)
        for t in modelTags { add(t) }

        // 2. LLM-confirmed OCR rescue, gated by the bilingual stop-list
        let llmLower = llmRawResponse.lowercased()
        for line in ocr {
            for tok in line.split(whereSeparator: { !$0.isLetter }) {
                let s = String(tok).lowercased()
                guard s.count >= 4 && s.count <= 20 else { continue }
                guard !Self.ocrStopwords.contains(s) else { continue }
                if llmLower.contains(s) {
                    add(s)
                }
            }
        }

        return out
    }

    /// Common English + French function/junk words that should never appear as tags
    /// even when they survive the LLM cross-check. Keeps the rescue door open for short
    /// brand names (Sony, Lego, Audi, Nike, ...) while dropping observed leaks like
    /// "type" (from "TYPE-C") and obvious noise like "with", "avec", "mode".
    private static let ocrStopwords: Set<String> = [
        // English/shared generic
        "type", "size", "name", "code", "view", "mode", "page", "item",
        "list", "info", "data", "time", "date", "line", "file", "user",
        "test", "free", "made", "from", "with", "this", "that", "your",
        "more", "less", "back", "next", "open", "save", "load", "menu",
        "edit", "help", "show", "hide", "true", "false", "null", "none",
        "left", "right", "down", "high", "long", "wide", "tall", "thin",
        "yes", "no", "ok", "off", "on",
        // French-specific function words
        "avec", "sans", "pour", "sont", "dans", "leur", "tous", "deux",
        "trois", "plus", "sous", "sur", "mais", "tres", "tout", "vous",
        "nous", "ceux", "elle", "etre", "fait", "voir", "dire", "cela",
        "ceci", "donc", "alors", "puis", "ainsi", "meme", "aussi",
        "selon", "entre", "chaque", "quand", "quel", "quelle",
    ]
}
