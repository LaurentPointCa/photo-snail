import Foundation
import PhotoSnailCore
import PhotoSnailPhotos

// Usage: photo-snail-app [--list [N]] [--list-models] [--api-test] [--verify-queue]
//                      [--provider ollama|openai]
//                      [--model <name>] [--bare|--hybrid] [--no-downsize]
//                      [--db <path>] [--concurrency <N>]
//                      [--sentinel <marker>] [--keep-sentinel]
//                      [--ollama-url <url>] [--ollama-key <key>] [--ollama-header K=V ...]
//                      [--openai-url <url>] [--openai-key <key>] [--openai-header K=V ...]
//                      [--dry-run] [--limit <N>]
//
//   --list [N]           List N most-recent image assets and exit (default: 10)
//   --list-models        Print the current provider's installed/available models and exit
//   --api-test           Probe the current provider with current config and exit.
//                        Alias: --ollama-test (kept for back-compat).
//   --verify-queue       Open the queue (triggers any pending schema migration),
//                        print schema version + row counts, and exit.
//   --provider NAME      LLM backend: ollama (default) or openai (OpenAI-compatible,
//                        local endpoints only — mlx-vlm, LM Studio, vLLM, ...).
//   --model <name>       Model name. Ollama: gemma4:31b, llava:13b, ...
//                        OpenAI-compatible: whatever `/v1/models` returns.
//   --bare               Pure bare prompt, no Vision pre-pass (control arm)
//   --hybrid             Inject Vision findings into the LLM prompt (slower)
//   (default)            Side-channel (v3): Vision runs for OCR rescue, bare prompt
//   --no-downsize        Send original image (default: downsize to 1024 px)
//   --db <path>          Override queue DB location
//   --concurrency <N>    Number of concurrent workers (default: 1)
//   --sentinel <marker>  Override the sentinel marker. Saved to settings.json.
//   --keep-sentinel      Keep existing sentinel on model family change.
//   --ollama-url <url>   Ollama base URL (default: http://localhost:11434)
//   --ollama-key <key>   Ollama API key (Bearer). Env: PHOTO_SNAIL_OLLAMA_API_KEY.
//   --ollama-header K=V  Custom Ollama header (repeatable).
//   --openai-url <url>   OpenAI-compatible base URL (e.g. http://host:9090/v1)
//   --openai-key <key>   OpenAI API key (Bearer). Env: PHOTO_SNAIL_OPENAI_API_KEY.
//   --openai-header K=V  Custom OpenAI header (repeatable).
//   --dry-run            Run pipeline but skip Photos.app write-back + queue mutation
//   --limit <N>          Stop after N new photos processed (default: unlimited)

struct AppArgs {
    var list: Int? = nil          // nil = not listing, Int = number to list
    var listModels: Bool = false
    var apiTest: Bool = false
    var verifyQueue: Bool = false
    var scanMulti: Bool = false
    var cleanMulti: Bool = false
    var applyWrites: Bool = false

    // CLI overrides; nil means "use whatever is in settings.json"
    var apiProvider: LLMProvider? = nil
    var model: String? = nil
    var sentinel: String? = nil
    var keepSentinel: Bool = false
    var ollamaURL: String? = nil
    var ollamaKey: String? = nil
    var ollamaHeaders: [String: String] = [:]
    var openaiURL: String? = nil
    var openaiKey: String? = nil
    var openaiHeaders: [String: String] = [:]

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
        case "--api-test", "--ollama-test":
            out.apiTest = true
        case "--verify-queue":
            out.verifyQueue = true
        case "--scan-multi":
            out.scanMulti = true
        case "--clean-multi":
            out.cleanMulti = true
        case "--apply":
            out.applyWrites = true
        case "--provider":
            i += 1
            if i < argv.count {
                switch argv[i].lowercased() {
                case "ollama":
                    out.apiProvider = .ollama
                case "openai", "openai-compatible":
                    out.apiProvider = .openaiCompatible
                default:
                    FileHandle.standardError.write(Data("unknown --provider: \(argv[i]) (expected: ollama|openai)\n".utf8))
                }
            }
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
        case "--openai-url":
            i += 1
            if i < argv.count { out.openaiURL = argv[i] }
        case "--openai-key":
            i += 1
            if i < argv.count { out.openaiKey = argv[i] }
        case "--openai-header":
            i += 1
            if i < argv.count {
                let kv = argv[i]
                if let eq = kv.firstIndex(of: "=") {
                    let k = String(kv[..<eq])
                    let v = String(kv[kv.index(after: eq)...])
                    if !k.isEmpty { out.openaiHeaders[k] = v }
                } else {
                    FileHandle.standardError.write(Data("ignoring --openai-header without '=': \(kv)\n".utf8))
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
    usage: photo-snail-app [--list [N]] [--list-models] [--api-test]
                           [--provider ollama|openai]
                           [--model <name>] [--bare|--hybrid] [--no-downsize]
                           [--db <path>] [--concurrency <N>]
                           [--sentinel <marker>] [--keep-sentinel]
                           [--ollama-url <url>] [--ollama-key <key>] [--ollama-header K=V ...]
                           [--openai-url <url>] [--openai-key <key>] [--openai-header K=V ...]
                           [--dry-run] [--limit <N>]

    --provider openai selects a locally-hosted OpenAI-compatible endpoint
    (mlx-vlm, LM Studio, vLLM, ...). See CLAUDE.md for the sentinel rule
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

    // 0. Provider selection
    if let p = args.apiProvider {
        s.apiProvider = p
    }

    // 1a. Ollama connection overrides
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

    // 1b. OpenAI-compatible connection overrides
    if let url = args.openaiURL {
        if let parsed = URL(string: url) {
            s.openai.baseURL = parsed
        } else {
            eprint("ERROR: --openai-url is not a valid URL: \(url)")
            exit(1)
        }
    }
    if let key = args.openaiKey {
        s.openai.apiKey = key.isEmpty ? nil : key
    }
    if !args.openaiHeaders.isEmpty {
        for (k, v) in args.openaiHeaders {
            s.openai.headers[k] = v
        }
    }

    // 2. Model + sentinel — interlocked by the family-change gate.
    let newModel = args.model ?? loaded.model
    let modelChanged = (newModel != loaded.model)
    // Capture the loaded sentinel BEFORE we touch `s.model`; under the
    // per-family schema, `s.sentinel` is derived from the active family so
    // swapping the model first would change what we'd read here.
    let loadedSentinel = loaded.sentinel

    if let explicit = args.sentinel {
        // Explicit sentinel always wins.
        s.model = newModel
        s.sentinel = explicit
    } else if args.keepSentinel {
        // Keep existing sentinel even if family is changing. Re-apply it
        // explicitly — if the family changed, it lands as a customSentinel
        // pin on the new family's ModelConfig.
        s.model = newModel
        s.sentinel = loadedSentinel
    } else if modelChanged {
        // No explicit sentinel, no --keep-sentinel: gate on family change.
        if Sentinel.propose(forModel: newModel, currentSentinel: loaded.sentinel) != nil {
            // Family changed → refuse without explicit choice.
            let oldFamily = Sentinel.family(ofSentinel: loaded.sentinel) ?? "(unknown)"
            let newFamily = Sentinel.shortFamily(of: newModel)
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

private func runListModels(settings: Settings) async {
    let client = settings.makeLLMClient()
    switch settings.apiProvider {
    case .ollama:
        eprint("provider: ollama  url: \(settings.ollama.baseURL.absoluteString)  key: \(settings.ollama.redactedKey)")
    case .openaiCompatible:
        eprint("provider: openai-compatible  url: \(settings.openai.baseURL.absoluteString)  key: \(settings.openai.redactedKey)")
    }
    do {
        let models = try await client.listModels()
        if models.isEmpty {
            print("(no models available)")
            return
        }
        // Sort by name for stable output.
        let sorted = models.sorted { $0.name < $1.name }
        let nameWidth = max(20, sorted.map(\.name.count).max() ?? 20)
        for m in sorted {
            let marker = (m.name == settings.model) ? "*" : " "
            let padded = m.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let size = m.sizeLabel ?? ""
            print("\(marker) \(padded)  \(size)")
        }
        print("")
        print("(* = current; set with --model <name>)")
    } catch {
        eprint("ERROR listing models: \(error)")
        exit(1)
    }
}

// MARK: - --verify-queue

/// Opens the queue (running any pending schema migration) and prints a short
/// status report. Exits with code 0 on success, 1 on any error. Does NOT touch
/// PhotoKit or Ollama — this is purely a local SQLite health check.
private func runVerifyQueue(dbPath: URL?) async {
    let path = dbPath ?? AssetQueue.defaultDBPath
    eprint("queue: \(path.path)")

    // Detect whether a backup exists before we open the queue — if the DB is
    // still at v0 the open will create one, and we want to report that fact.
    let backupPath = path.deletingLastPathComponent()
        .appendingPathComponent("queue.sqlite.pre-v1.backup")
    let hadBackupBefore = FileManager.default.fileExists(atPath: backupPath.path)

    let queue: AssetQueue
    do {
        queue = try AssetQueue(dbPath: path)
    } catch {
        eprint("FAIL — open failed: \(error)")
        exit(1)
    }

    // Fetch stats via the public API.
    let stats: AssetQueue.Stats
    do {
        stats = try await queue.stats()
    } catch {
        eprint("FAIL — stats failed: \(error)")
        exit(1)
    }

    // Report backup state.
    let hadBackupAfter = FileManager.default.fileExists(atPath: backupPath.path)
    if hadBackupAfter && !hadBackupBefore {
        eprint("migration: v0 → v1 (backup created at \(backupPath.lastPathComponent))")
    } else if hadBackupAfter {
        eprint("migration: already at v1 (prior backup present)")
    } else {
        eprint("migration: already at v1 (no prior v0 backup)")
    }

    print("OK — schema v\(AssetQueue.currentSchemaVersion), \(stats.total) rows "
          + "(done=\(stats.done) pending=\(stats.pending) failed=\(stats.failed) in_progress=\(stats.inProgress))")
    exit(0)
}

// MARK: - --api-test

private func runApiTest(settings: Settings) async {
    let client = settings.makeLLMClient()
    switch settings.apiProvider {
    case .ollama:
        eprint("provider: ollama  url: \(settings.ollama.baseURL.absoluteString)  key: \(settings.ollama.redactedKey)")
    case .openaiCompatible:
        eprint("provider: openai-compatible  url: \(settings.openai.baseURL.absoluteString)  key: \(settings.openai.redactedKey)")
    }
    do {
        let models = try await client.listModels()
        print("OK — \(settings.apiProvider.displayName) responded, \(models.count) model(s) available")
        exit(0)
    } catch {
        eprint("FAIL — \(error)")
        exit(1)
    }
}

// MARK: - --scan-multi

/// Read-only diagnostic that scans every `done` asset in the queue,
/// reads its current Photos.app description via AppleScript, and reports
/// rows that look "accumulated" — more than one PhotoSnail sentinel,
/// more than one `\n\n---\n\n` separator, or unusual length for a clean
/// one-touch write.
///
/// Iterates one asset at a time (NSAppleScript has to run on the main
/// thread; each call is ~100ms). For the user's ~4k done rows this takes
/// a few minutes — acceptable for a one-shot remediation audit.
///
/// Does NOT mutate anything: no Photos.app writes, no queue updates. The
/// output is a TSV-ish report the user can eyeball or feed into a later
/// cleanup pass.
@MainActor
private func runScanMulti(dbPath: URL?) async {
    let status = await PhotoLibrary.requestAuth()
    guard status == .authorized else {
        eprint("ERROR: Photo Library auth \(PhotoLibrary.authStatusLabel(status))")
        exit(1)
    }

    let path = dbPath ?? AssetQueue.defaultDBPath
    eprint("queue: \(path.path)")
    let queue: AssetQueue
    do {
        queue = try AssetQueue(dbPath: path)
    } catch {
        eprint("ERROR opening queue: \(error)")
        exit(1)
    }

    // Pull every done id regardless of which sentinel was used — the
    // report needs to span sentinel bumps and provider switches.
    var doneIds: [String] = []
    do {
        let sentinels = try await queue.distinctSentinels()
        for s in sentinels {
            let ids = try await queue.idsWithSentinel(s)
            doneIds.append(contentsOf: ids)
        }
    } catch {
        eprint("ERROR reading done ids: \(error)")
        exit(1)
    }
    // De-duplicate in case a row somehow ended up with multiple sentinels
    // (shouldn't, but defensive).
    doneIds = Array(Set(doneIds))
    eprint("scanning \(doneIds.count) done asset(s)...")

    // Reuse the same pattern as Sentinel.containsAnySentinel so this
    // diagnostic can never diverge from the detection used by the write-back
    // splitter. We call numberOfMatches(...) to COUNT sentinels, while
    // containsAnySentinel only needs presence.
    let sentinelRE = try! NSRegularExpression(
        pattern: Sentinel.sentinelPattern,
        options: []
    )
    let separator = "\n\n---\n\n"

    struct Finding {
        let id: String
        let sentinels: Int
        let separators: Int
        let length: Int
        let description: String
    }
    var suspicious: [Finding] = []
    var hardErrors = 0
    var scanned = 0
    let startedAt = Date()

    for id in doneIds {
        let uuid = PhotoLibrary.uuidPrefix(id)
        let desc: String
        do {
            desc = try PhotosScripter.readDescription(uuid: uuid)
        } catch {
            hardErrors += 1
            continue
        }
        let range = NSRange(desc.startIndex..., in: desc)
        let sentinels = sentinelRE.numberOfMatches(in: desc, options: [], range: range)
        let separators = desc.components(separatedBy: separator).count - 1
        if sentinels >= 2 || separators >= 2 {
            suspicious.append(Finding(
                id: id, sentinels: sentinels, separators: separators,
                length: desc.count, description: desc
            ))
        }
        scanned += 1
        if scanned % 100 == 0 {
            let elapsed = Date().timeIntervalSince(startedAt)
            let rate = Double(scanned) / max(elapsed, 0.001)
            let remaining = Double(doneIds.count - scanned) / max(rate, 0.001)
            eprint("  \(scanned)/\(doneIds.count) · suspicious=\(suspicious.count) · errors=\(hardErrors) · ~\(Int(remaining))s left")
        }
    }

    let elapsed = Date().timeIntervalSince(startedAt)
    eprint("scan done in \(String(format: "%.1f", elapsed))s — \(scanned) read, \(hardErrors) errors, \(suspicious.count) suspicious")
    print("")
    print("=== Suspicious descriptions (≥2 sentinels OR ≥2 separators) ===")
    if suspicious.isEmpty {
        print("(none — library is clean)")
    } else {
        print("uuid-prefix                           sentinels  seps  len  preview")
        for f in suspicious.sorted(by: { $0.sentinels == $1.sentinels ? $0.separators > $1.separators : $0.sentinels > $1.sentinels }) {
            let short = String(PhotoLibrary.uuidPrefix(f.id))
            let oneline = f.description
                .replacingOccurrences(of: "\n", with: "⏎")
                .prefix(80)
            print(String(format: "%@  %8d  %4d  %4d  %@",
                         short, f.sentinels, f.separators, f.length, String(oneline)))
        }
    }
    exit(0)
}

// MARK: - --clean-multi

/// Collapse descriptions that accumulated multiple PhotoSnail payloads
/// before the 2026-04-20 regex fix. Dry-run by default: prints every
/// candidate with a before/after length diff. `--apply` actually writes
/// the cleaned description back via `PhotosScripter.runBatch`, which is
/// the same code path used by the worker loop (read-check-write pattern
/// with pre/post verification inside one AppleScript block).
///
/// Uses `Pipeline.collapseMultiSegment` to compute the cleaned text —
/// keeps user prefix (anything before the first sentinel segment) and
/// user suffix (anything after the last sentinel segment), drops every
/// middle PhotoSnail segment, retains only the newest.
@MainActor
private func runCleanMulti(dbPath: URL?, apply: Bool) async {
    let status = await PhotoLibrary.requestAuth()
    guard status == .authorized else {
        eprint("ERROR: Photo Library auth \(PhotoLibrary.authStatusLabel(status))")
        exit(1)
    }

    let path = dbPath ?? AssetQueue.defaultDBPath
    eprint("queue: \(path.path)")
    let queue: AssetQueue
    do {
        queue = try AssetQueue(dbPath: path)
    } catch {
        eprint("ERROR opening queue: \(error)")
        exit(1)
    }

    var doneIds: [String] = []
    do {
        let sentinels = try await queue.distinctSentinels()
        for s in sentinels {
            let ids = try await queue.idsWithSentinel(s)
            doneIds.append(contentsOf: ids)
        }
    } catch {
        eprint("ERROR reading done ids: \(error)")
        exit(1)
    }
    doneIds = Array(Set(doneIds))
    eprint("scanning \(doneIds.count) done asset(s) for collapse candidates...")
    if !apply {
        eprint("DRY RUN — no writes. Pass --apply to actually rewrite descriptions.")
    }

    struct Candidate {
        let id: String
        let before: String
        let after: String
    }
    var candidates: [Candidate] = []
    var readErrors = 0
    var scanned = 0
    let startedAt = Date()

    for id in doneIds {
        let uuid = PhotoLibrary.uuidPrefix(id)
        let current: String
        do {
            current = try PhotosScripter.readDescription(uuid: uuid)
        } catch {
            readErrors += 1
            continue
        }
        if let cleaned = Pipeline.collapseMultiSegment(current), cleaned != current {
            candidates.append(Candidate(id: id, before: current, after: cleaned))
        }
        scanned += 1
        if scanned % 100 == 0 {
            let elapsed = Date().timeIntervalSince(startedAt)
            let rate = Double(scanned) / max(elapsed, 0.001)
            let remaining = Double(doneIds.count - scanned) / max(rate, 0.001)
            eprint("  \(scanned)/\(doneIds.count) · candidates=\(candidates.count) · errors=\(readErrors) · ~\(Int(remaining))s left")
        }
    }

    let scanElapsed = Date().timeIntervalSince(startedAt)
    eprint("scan done in \(String(format: "%.1f", scanElapsed))s — \(scanned) read, \(readErrors) errors, \(candidates.count) collapse candidates")
    print("")

    if candidates.isEmpty {
        print("(nothing to clean)")
        exit(0)
    }

    print("=== Collapse candidates ===")
    var totalBefore = 0
    var totalAfter = 0
    for c in candidates {
        totalBefore += c.before.count
        totalAfter += c.after.count
        let saved = c.before.count - c.after.count
        let short = String(PhotoLibrary.uuidPrefix(c.id))
        print(String(format: "%@  %5d → %5d  (−%d bytes)",
                     short, c.before.count, c.after.count, saved))
    }
    let totalSaved = totalBefore - totalAfter
    print("")
    print(String(format: "Total: %d bytes → %d bytes (−%d, %.1f%% reduction)",
                 totalBefore, totalAfter, totalSaved,
                 100.0 * Double(totalSaved) / Double(max(totalBefore, 1))))

    if !apply {
        print("")
        print("Dry run — no changes written. Re-run with --clean-multi --apply to rewrite.")
        exit(0)
    }

    // Write phase. Same PhotosScripter.runBatch the worker loop uses so
    // we benefit from its pre/post verification. If any write fails, log
    // and continue — we can re-run; the already-cleaned rows will simply
    // be skipped by `collapseMultiSegment` returning nil.
    print("")
    print("=== Writing cleaned descriptions ===")
    var wrote = 0
    var writeErrors = 0
    let writeStarted = Date()
    for c in candidates {
        let uuid = PhotoLibrary.uuidPrefix(c.id)
        do {
            let res = try PhotosScripter.runBatch(uuid: uuid, descriptionPayload: c.after)
            if res.postDescription != c.after {
                eprint("  \(uuid)  WARN: post-description doesn't match written payload")
                writeErrors += 1
            } else {
                wrote += 1
            }
        } catch {
            eprint("  \(uuid)  ERROR: \(error)")
            writeErrors += 1
        }
        if (wrote + writeErrors) % 10 == 0 {
            eprint("  \(wrote + writeErrors)/\(candidates.count) written (\(writeErrors) errors)")
        }
    }
    let writeElapsed = Date().timeIntervalSince(writeStarted)
    print("")
    print(String(format: "Wrote %d/%d (errors: %d) in %.1fs",
                 wrote, candidates.count, writeErrors, writeElapsed))
    exit(writeErrors == 0 ? 0 : 1)
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
            await runListModels(settings: runtime)
            return
        }
        if args.apiTest {
            await runApiTest(settings: runtime)
            return
        }
        if args.verifyQueue {
            await runVerifyQueue(dbPath: args.dbPath.map { URL(fileURLWithPath: $0) })
            return
        }
        if args.scanMulti {
            await runScanMulti(dbPath: args.dbPath.map { URL(fileURLWithPath: $0) })
            return
        }
        if args.cleanMulti {
            await runCleanMulti(
                dbPath: args.dbPath.map { URL(fileURLWithPath: $0) },
                apply: args.applyWrites
            )
            return
        }

        // 5. Persist effective settings if anything actually changed on the
        //    settings layer (not the env-var layer).
        if effective.model != loaded.model
            || effective.sentinel != loaded.sentinel
            || effective.apiProvider != loaded.apiProvider
            || effective.ollama.baseURL != loaded.ollama.baseURL
            || effective.ollama.apiKey != loaded.ollama.apiKey
            || effective.ollama.headers != loaded.ollama.headers
            || effective.openai.baseURL != loaded.openai.baseURL
            || effective.openai.apiKey != loaded.openai.apiKey
            || effective.openai.headers != loaded.openai.headers {
            do {
                try effective.save()
                eprint("settings: saved \(Settings.defaultPath.path)")
            } catch {
                eprint("WARNING: failed to save settings: \(error)")
                // Non-fatal — continue with the in-memory effective settings.
            }
        }

        eprint("provider: \(runtime.apiProvider.rawValue)   model: \(runtime.model)   sentinel: \(runtime.sentinel)")
        switch runtime.apiProvider {
        case .ollama:
            eprint("ollama: \(runtime.ollama.baseURL.absoluteString)  key: \(runtime.ollama.redactedKey)")
        case .openaiCompatible:
            eprint("openai: \(runtime.openai.baseURL.absoluteString)  key: \(runtime.openai.redactedKey)")
        }

        // 6. Build runner config and start the batch.
        var config = QueueRunner.Config()
        config.settings = runtime
        config.promptStyle = args.promptStyle
        config.noDownsize = args.noDownsize
        config.concurrency = args.concurrency
        config.dryRun = args.dryRun
        config.limit = args.limit
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
