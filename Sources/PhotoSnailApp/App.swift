import Foundation
import PhotoSnailCore

// Usage: photo-snail-app [--list [N]] [--list-models] [--ollama-test]
//                      [--model <name>] [--bare|--hybrid] [--no-downsize]
//                      [--db <path>] [--concurrency <N>]
//                      [--sentinel <marker>] [--keep-sentinel]
//                      [--ollama-url <url>] [--ollama-key <key>] [--ollama-header K=V ...]
//                      [--dry-run] [--limit <N>]
//
//   --list [N]           List N most-recent image assets and exit (default: 10)
//   --list-models        Print Ollama's installed models and exit
//   --ollama-test        Probe Ollama (/api/tags) with current config and exit
//   --model <name>       Ollama model to use (e.g. gemma4:31b, llava:13b)
//                        Persists to settings.json. Switching to a different family
//                        requires --sentinel or --keep-sentinel.
//   --bare               Pure bare prompt, no Vision pre-pass (control arm)
//   --hybrid             Inject Vision findings into the LLM prompt (slower)
//   (default)            Side-channel (v3): Vision runs for OCR rescue, bare prompt
//   --no-downsize        Send original image to Ollama (default: downsize to 1024 px)
//   --db <path>          Override queue DB location
//   --concurrency <N>    Number of concurrent workers (default: 1)
//   --sentinel <marker>  Override the sentinel marker. Saved to settings.json.
//   --keep-sentinel      Keep the existing settings.json sentinel even when --model
//                        changes the model family. Without this (and without
//                        --sentinel), a family change is rejected with an error.
//   --ollama-url <url>   Ollama base URL (default: http://localhost:11434)
//   --ollama-key <key>   API key, sent as Authorization: Bearer <key>.
//                        Saved to settings.json (0600). Set
//                        PHOTO_SNAIL_OLLAMA_API_KEY in env to avoid persisting.
//   --ollama-header K=V  Custom header (repeatable). Use for proxies with
//                        non-Bearer auth schemes (Basic, X-API-Key, etc.).
//                        Headers override --ollama-key if both set Authorization.
//   --dry-run            Run pipeline but skip Photos.app write-back
//   --limit <N>          Stop after N new photos processed (default: unlimited)

struct AppArgs {
    var list: Int? = nil          // nil = not listing, Int = number to list
    var listModels: Bool = false
    var ollamaTest: Bool = false

    // CLI overrides; nil means "use whatever is in settings.json"
    var model: String? = nil
    var sentinel: String? = nil
    var keepSentinel: Bool = false
    var ollamaURL: String? = nil
    var ollamaKey: String? = nil
    var ollamaHeaders: [String: String] = [:]

    var promptStyle: PromptStyle = .sideChannel
    var noDownsize: Bool = false
    var dbPath: String? = nil
    var concurrency: Int = 1
    var dryRun: Bool = false
    var limit: Int = 0            // 0 = unlimited
}

func parseArgs(_ argv: [String]) -> AppArgs {
    var out = AppArgs()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--list":
            if i + 1 < argv.count, let n = Int(argv[i + 1]), n >= 1 {
                out.list = n
                i += 1
            } else {
                out.list = 10
            }
        case "--list-models":
            out.listModels = true
        case "--ollama-test":
            out.ollamaTest = true
        case "--model":
            i += 1
            if i < argv.count { out.model = argv[i] }
        case "--bare":
            out.promptStyle = .bare
        case "--hybrid":
            out.promptStyle = .hybrid
        case "--no-downsize":
            out.noDownsize = true
        case "--db":
            i += 1
            if i < argv.count { out.dbPath = argv[i] }
        case "--concurrency":
            i += 1
            if i < argv.count, let n = Int(argv[i]), n >= 1 { out.concurrency = n }
        case "--sentinel":
            i += 1
            if i < argv.count { out.sentinel = argv[i] }
        case "--keep-sentinel":
            out.keepSentinel = true
        case "--ollama-url":
            i += 1
            if i < argv.count { out.ollamaURL = argv[i] }
        case "--ollama-key":
            i += 1
            if i < argv.count { out.ollamaKey = argv[i] }
        case "--ollama-header":
            i += 1
            if i < argv.count {
                let kv = argv[i]
                if let eq = kv.firstIndex(of: "=") {
                    let k = String(kv[..<eq])
                    let v = String(kv[kv.index(after: eq)...])
                    if !k.isEmpty { out.ollamaHeaders[k] = v }
                } else {
                    FileHandle.standardError.write(Data("ignoring --ollama-header without '=': \(kv)\n".utf8))
                }
            }
        case "--dry-run":
            out.dryRun = true
        case "--limit":
            i += 1
            if i < argv.count, let n = Int(argv[i]), n >= 1 { out.limit = n }
        case "-h", "--help":
            printHelp()
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(a)\n".utf8))
        }
        i += 1
    }
    return out
}

private func printHelp() {
    print("""
    usage: photo-snail-app [--list [N]] [--list-models] [--ollama-test]
                           [--model <name>] [--bare|--hybrid] [--no-downsize]
                           [--db <path>] [--concurrency <N>]
                           [--sentinel <marker>] [--keep-sentinel]
                           [--ollama-url <url>] [--ollama-key <key>] [--ollama-header K=V ...]
                           [--dry-run] [--limit <N>]

    Run with --help to see this message. See CLAUDE.md for the sentinel rule
    and the API key storage tradeoff.
    """)
}

private func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Settings + CLI override merge

/// Build the effective settings for this run by overlaying CLI flags onto the
/// loaded settings. Does NOT apply env-var overrides — those are layered on top
/// at OllamaClient construction time via `withEnvOverrides()`.
///
/// Side effect: applies the family-change gate. If `--model` changes the model
/// family from the loaded settings' sentinel family AND neither `--sentinel` nor
/// `--keep-sentinel` is provided, this prints an error and exits the process.
private func mergeSettings(loaded: Settings, args: AppArgs) -> Settings {
    var s = loaded

    // 1. Ollama connection overrides
    if let url = args.ollamaURL {
        if let parsed = URL(string: url) {
            s.ollama.baseURL = parsed
        } else {
            eprint("ERROR: --ollama-url is not a valid URL: \(url)")
            exit(1)
        }
    }
    if let key = args.ollamaKey {
        s.ollama.apiKey = key.isEmpty ? nil : key
    }
    if !args.ollamaHeaders.isEmpty {
        for (k, v) in args.ollamaHeaders {
            s.ollama.headers[k] = v
        }
    }

    // 2. Model + sentinel — interlocked by the family-change gate.
    let newModel = args.model ?? loaded.model
    let modelChanged = (newModel != loaded.model)

    if let explicit = args.sentinel {
        // Explicit sentinel always wins.
        s.model = newModel
        s.sentinel = explicit
    } else if args.keepSentinel {
        // Keep existing sentinel even if family is changing.
        s.model = newModel
        // s.sentinel unchanged
    } else if modelChanged {
        // No explicit sentinel, no --keep-sentinel: gate on family change.
        if Sentinel.propose(forModel: newModel, currentSentinel: loaded.sentinel) != nil {
            // Family changed → refuse without explicit choice.
            let oldFamily = Sentinel.family(ofSentinel: loaded.sentinel) ?? "(unknown)"
            let newFamily = Sentinel.family(of: newModel)
            let proposed = Sentinel.make(family: newFamily, version: 1)
            eprint("""
            ERROR: switching from model '\(loaded.model)' (family '\(oldFamily)') \
            to '\(newModel)' (family '\(newFamily)')
            This changes the sentinel used for write-back and bootstrap search.
            Pass one of:
              --sentinel \(proposed)   propose a new sentinel for the new family
              --sentinel ai:\(oldFamily)-v2   bump the version within the current family
              --keep-sentinel                 keep '\(loaded.sentinel)' (mixes models under one sentinel)
            """)
            exit(2)
        } else {
            // Same family — accept silently, sentinel unchanged.
            s.model = newModel
        }
    }
    // else: no model change, no sentinel override, no keep flag — nothing to do.

    return s
}

// MARK: - --list-models

private func runListModels(connection: OllamaConnection, currentModel: String) async {
    eprint("ollama: \(connection.baseURL.absoluteString)  key: \(connection.redactedKey)")
    let client = OllamaClient(connection: connection)
    do {
        let models = try await client.listModels()
        if models.isEmpty {
            print("(no models installed)")
            return
        }
        // Sort by name for stable output.
        let sorted = models.sorted { $0.name < $1.name }
        let nameWidth = max(20, sorted.map(\.name.count).max() ?? 20)
        for m in sorted {
            let marker = (m.name == currentModel) ? "*" : " "
            let padded = m.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            print("\(marker) \(padded)  \(m.sizeLabel)")
        }
        print("")
        print("(* = current; set with --model <name>)")
    } catch {
        eprint("ERROR listing models: \(error)")
        exit(1)
    }
}

// MARK: - --ollama-test

private func runOllamaTest(connection: OllamaConnection) async {
    eprint("ollama: \(connection.baseURL.absoluteString)  key: \(connection.redactedKey)")
    let client = OllamaClient(connection: connection)
    do {
        let models = try await client.listModels()
        print("OK — Ollama responded, \(models.count) model(s) installed")
        exit(0)
    } catch {
        eprint("FAIL — \(error)")
        exit(1)
    }
}

@main
struct App {
    static func main() async {
        let args = parseArgs(CommandLine.arguments)

        // 1. Load settings (or defaults if missing). Corrupt file → fail loud.
        let loaded: Settings
        do {
            loaded = try Settings.load()
        } catch {
            eprint("ERROR loading settings.json: \(error)")
            eprint("Delete \(Settings.defaultPath.path) to reset to defaults.")
            exit(1)
        }

        // 2. Build the effective settings (with CLI overrides + family gate).
        //    The gate may exit() if a family change is unresolved.
        let effective = mergeSettings(loaded: loaded, args: args)

        // 3. Apply env-var overrides for runtime use ONLY (never persisted).
        let runtime = effective.withEnvOverrides()

        // 4. Diagnostic / read-only commands — they don't touch the queue or settings file.
        if let n = args.list {
            await runList(n: n)
            return
        }
        if args.listModels {
            await runListModels(connection: runtime.ollama, currentModel: runtime.model)
            return
        }
        if args.ollamaTest {
            await runOllamaTest(connection: runtime.ollama)
            return
        }

        // 5. Persist effective settings if anything actually changed on the
        //    settings layer (not the env-var layer).
        if effective.model != loaded.model
            || effective.sentinel != loaded.sentinel
            || effective.ollama.baseURL != loaded.ollama.baseURL
            || effective.ollama.apiKey != loaded.ollama.apiKey
            || effective.ollama.headers != loaded.ollama.headers {
            do {
                try effective.save()
                eprint("settings: saved \(Settings.defaultPath.path)")
            } catch {
                eprint("WARNING: failed to save settings: \(error)")
                // Non-fatal — continue with the in-memory effective settings.
            }
        }

        eprint("model: \(runtime.model)   sentinel: \(runtime.sentinel)")
        eprint("ollama: \(runtime.ollama.baseURL.absoluteString)  key: \(runtime.ollama.redactedKey)")

        // 6. Build runner config and start the batch.
        var config = QueueRunner.Config()
        config.model = runtime.model
        config.promptStyle = args.promptStyle
        config.noDownsize = args.noDownsize
        config.concurrency = args.concurrency
        config.sentinel = runtime.sentinel
        config.dryRun = args.dryRun
        config.limit = args.limit
        config.connection = runtime.ollama
        if let db = args.dbPath {
            config.dbPath = URL(fileURLWithPath: db)
        }

        await QueueRunner.run(config: config)
    }

    static func runList(n: Int) async {
        let status = await PhotoLibrary.requestAuth()
        guard status == .authorized else {
            eprint("ERROR: Photo Library auth \(PhotoLibrary.authStatusLabel(status))")
            exit(1)
        }

        let rows = PhotoLibrary.listFirst(n: n)
        print("\(rows.count) most-recent image assets:")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for row in rows {
            let date = row.creationDate.map { df.string(from: $0) } ?? "?"
            let kind = PhotoLibrary.mediaTypeLabel(row.mediaType)
            print("  \(row.id)  \(date)  \(kind)")
        }
    }
}
