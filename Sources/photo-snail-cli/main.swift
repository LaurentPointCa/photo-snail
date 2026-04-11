import Foundation
import PhotoSnailCore

// Usage: photo-snail-cli [--model <name>] [--bare|--hybrid] [--no-downsize] [--json]
//                      [--queue [--db <path>] [--concurrency <N>]] <image-path> [...]
//   --model              Ollama model name (default: gemma4:31b)
//   --bare               Pure bare prompt, no Vision pre-pass at all (control arm)
//   --hybrid             Inject Vision findings into the LLM prompt (slower, kept for comparison)
//   (default)            Side-channel (v3): Vision runs for OCR rescue + structured metadata,
//                        but the LLM gets the bare prompt
//   --no-downsize        Send the original image to Ollama (default: downsize to 1024 px long edge)
//   --json               Emit JSON instead of human-readable text (one-shot mode only)
//   --queue              Queue mode: persist progress to SQLite, resume on restart, retry transient failures
//   --db <path>          Override the queue DB location (default: ~/Library/Application Support/photo-snail/queue.sqlite)
//   --concurrency <N>    Number of concurrent workers in queue mode (default: 1)

struct CLIArgs {
    var model: String = "gemma4:31b"
    var promptStyle: PromptStyle = .sideChannel
    var noDownsize: Bool = false
    var json: Bool = false
    var queue: Bool = false
    var dbPath: String? = nil
    var concurrency: Int = 1
    var paths: [String] = []
}

func parseArgs(_ argv: [String]) -> CLIArgs {
    var out = CLIArgs()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--model":
            i += 1
            if i < argv.count { out.model = argv[i] }
        case "--bare":
            out.promptStyle = .bare
        case "--hybrid":
            out.promptStyle = .hybrid
        case "--no-downsize":
            out.noDownsize = true
        case "--json":
            out.json = true
        case "--queue":
            out.queue = true
        case "--db":
            i += 1
            if i < argv.count { out.dbPath = argv[i] }
        case "--concurrency":
            i += 1
            if i < argv.count, let n = Int(argv[i]), n >= 1 { out.concurrency = n }
        case "-h", "--help":
            print("usage: photo-snail-cli [--model <name>] [--bare|--hybrid] [--no-downsize] [--json] [--queue [--db <path>] [--concurrency <N>]] <image-path> [...]")
            exit(0)
        default:
            out.paths.append(a)
        }
        i += 1
    }
    return out
}

func formatHuman(_ result: PipelineResult, promptStyle: PromptStyle) -> String {
    var lines: [String] = []
    let img = (result.imagePath as NSString).lastPathComponent
    let sentSize = result.caption.imageBytesSent
    let sentDims = "\(result.caption.imagePixelWidth)x\(result.caption.imagePixelHeight)"
    let sentKB = String(format: "%.0f KB", Double(sentSize) / 1024)
    lines.append("=========================================================")
    lines.append("IMAGE: \(img)  (source \(result.pixelWidth)x\(result.pixelHeight) → sent \(sentDims), \(sentKB))")
    lines.append("MODEL: \(result.caption.model)   PROMPT: \(promptStyle.rawValue)")
    lines.append("=========================================================")
    lines.append("")

    let v = result.vision
    if promptStyle != .bare {
        lines.append("[VISION]  \(String(format: "%.0f ms", v.elapsedSeconds * 1000))")
        let topLabels = v.classifications.prefix(8).map { "\($0.identifier) (\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", ")
        lines.append("  classifications: \(topLabels)")
        if v.animals.isEmpty {
            lines.append("  animals:         (none)")
        } else {
            let s = v.animals.map { "\($0.label) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")
            lines.append("  animals:         \(s)")
        }
        lines.append("  faces:           \(v.faces.count)")
        if v.ocrText.isEmpty {
            lines.append("  ocr:             (none)")
        } else {
            lines.append("  ocr:             \(v.ocrText.joined(separator: " | "))")
        }
        lines.append("")
    }

    let c = result.caption
    let promptTok = c.promptEvalTokens.map(String.init) ?? "?"
    let promptS = c.promptEvalSeconds.map { String(format: "%.1fs", $0) } ?? "?"
    let evalTok = c.evalTokens.map(String.init) ?? "?"
    let evalS = c.evalSeconds.map { String(format: "%.1fs", $0) } ?? "?"
    let loadS = c.loadSeconds.map { String(format: "%.2fs", $0) } ?? "?"
    lines.append("[OLLAMA]  total \(String(format: "%.1fs", c.elapsedSeconds))  (load \(loadS) | prompt \(promptTok)tok/\(promptS) | gen \(evalTok)tok/\(evalS))")
    lines.append("")

    lines.append("DESCRIPTION:")
    lines.append("  \(c.description)")
    lines.append("")
    lines.append("LLM TAGS: \(c.tags.joined(separator: ", "))")
    lines.append("MERGED TAGS: \(result.mergedTags.joined(separator: ", "))")
    lines.append("")
    lines.append("TOTAL: \(String(format: "%.1fs", result.totalElapsedSeconds))")
    return lines.joined(separator: "\n")
}

// MARK: - Queue runner (Phase E)

private func absolutePath(_ path: String) -> String {
    return URL(fileURLWithPath: path).standardizedFileURL.path
}

private func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

private func formatStats(_ stats: AssetQueue.Stats) -> String {
    return "\(stats.pending) pending, \(stats.inProgress) in_progress, \(stats.done) done, \(stats.failed) failed"
}

private func runQueue(args: CLIArgs) async {
    let dbURL = args.dbPath.map { URL(fileURLWithPath: $0) } ?? AssetQueue.defaultDBPath

    let queue: AssetQueue
    do {
        queue = try AssetQueue(dbPath: dbURL)
    } catch {
        eprint("ERROR opening queue at \(dbURL.path): \(error)")
        exit(1)
    }

    // Idempotent enqueue of any path arguments. Resolve to absolute paths so the queue ID
    // is stable regardless of cwd.
    if !args.paths.isEmpty {
        let absolute = args.paths.map(absolutePath)
        do {
            try await queue.enqueue(absolute)
        } catch {
            eprint("ERROR enqueueing paths: \(error)")
            exit(1)
        }
    }

    if let stats = try? await queue.stats() {
        print("queue (\(dbURL.path)): \(formatStats(stats))")
    }

    let model = args.model
    let promptStyle = args.promptStyle
    let imageOpts = OllamaImageOptions(downsize: !args.noDownsize)
    let concurrency = max(1, args.concurrency)
    let MAX_ATTEMPTS = 3
    let BACKOFF_SECONDS: [TimeInterval] = [10, 30, 60]

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<concurrency {
            group.addTask {
                // One Pipeline (and OllamaClient) per worker so we don't have to make
                // Pipeline @Sendable. Captured values (model, promptStyle, imageOpts) are
                // all Sendable; the non-Sendable Pipeline is constructed inside the task.
                let workerPipeline = Pipeline(
                    model: model,
                    promptStyle: promptStyle,
                    ollama: OllamaClient(imageOptions: imageOpts)
                )
                while true {
                    let claimResult: AssetQueue.Claim?
                    do {
                        claimResult = try await queue.claimNext()
                    } catch {
                        eprint("ERROR claimNext: \(error)")
                        return
                    }
                    guard let claim = claimResult else { return }
                    let id = claim.id
                    let attempts = claim.attempts

                    do {
                        let result = try await workerPipeline.process(imagePath: id)
                        try? await queue.markDone(id, result: result)
                        let secs = String(format: "%.1fs", result.totalElapsedSeconds)
                        let preview = result.caption.description.prefix(80)
                        print("[done a\(attempts)] \(secs) \(id) — \(preview)")
                    } catch let e as PhotoSnailError {
                        if e.isRetriable && attempts < MAX_ATTEMPTS {
                            try? await queue.recordRetry(id, error: e)
                            let delay = BACKOFF_SECONDS[attempts - 1]
                            print("[retry \(attempts)/\(MAX_ATTEMPTS)] \(id) — \(e.shortMessage), sleeping \(Int(delay))s")
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        } else {
                            try? await queue.markFailed(id, error: e)
                            print("[failed] \(id) — \(e.shortMessage)")
                        }
                    } catch {
                        let wrapped = PhotoSnailError.ollamaRequestFailed("\(error)")
                        try? await queue.markFailed(id, error: wrapped)
                        print("[failed] \(id) — \(error)")
                    }
                }
            }
        }
    }

    if let stats = try? await queue.stats() {
        print("queue final: \(formatStats(stats))")
    }
}

@main
struct CLI {
    static func main() async {
        let args = parseArgs(CommandLine.arguments)

        if args.queue {
            await runQueue(args: args)
            return
        }

        guard !args.paths.isEmpty else {
            FileHandle.standardError.write(Data("usage: photo-snail-cli [--model <name>] [--bare] [--no-downsize] [--json] [--queue [--db <path>] [--concurrency <N>]] <image-path> [...]\n".utf8))
            exit(1)
        }

        let imageOptions = OllamaImageOptions(downsize: !args.noDownsize)
        let ollama = OllamaClient(imageOptions: imageOptions)
        let pipeline = Pipeline(model: args.model, promptStyle: args.promptStyle, ollama: ollama)
        var results: [PipelineResult] = []

        for path in args.paths {
            do {
                let result = try await pipeline.process(imagePath: path)
                if !args.json {
                    print(formatHuman(result, promptStyle: args.promptStyle))
                    print("")
                }
                results.append(result)
            } catch {
                FileHandle.standardError.write(Data("ERROR processing \(path): \(error)\n".utf8))
            }
        }

        if args.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(results),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            }
        }
    }
}
