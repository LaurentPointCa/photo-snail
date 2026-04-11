import Foundation
import PhotoSnailCore

// Usage: photo-snail-app [--list [N]] [--model <name>] [--bare|--hybrid] [--no-downsize]
//                      [--db <path>] [--concurrency <N>] [--sentinel <marker>] [--dry-run]
//
//   --list [N]           List N most-recent image assets and exit (default: 10)
//   --model <name>       Ollama model name (default: gemma4:31b)
//   --bare               Pure bare prompt, no Vision pre-pass (control arm)
//   --hybrid             Inject Vision findings into the LLM prompt (slower)
//   (default)            Side-channel (v3): Vision runs for OCR rescue, bare prompt
//   --no-downsize        Send original image to Ollama (default: downsize to 1024 px)
//   --db <path>          Override queue DB location
//   --concurrency <N>    Number of concurrent workers (default: 1)
//   --sentinel <marker>  Sentinel marker in descriptions (default: ai:gemma4-v1)
//   --dry-run            Run pipeline but skip Photos.app write-back

struct AppArgs {
    var list: Int? = nil   // nil = not listing, Int = number to list
    var model: String = "gemma4:31b"
    var promptStyle: PromptStyle = .sideChannel
    var noDownsize: Bool = false
    var dbPath: String? = nil
    var concurrency: Int = 1
    var sentinel: String = "ai:gemma4-v1"
    var dryRun: Bool = false
    var limit: Int = 0     // 0 = unlimited
}

func parseArgs(_ argv: [String]) -> AppArgs {
    var out = AppArgs()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--list":
            // Optional N argument
            if i + 1 < argv.count, let n = Int(argv[i + 1]), n >= 1 {
                out.list = n
                i += 1
            } else {
                out.list = 10
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
        case "--dry-run":
            out.dryRun = true
        case "--limit":
            i += 1
            if i < argv.count, let n = Int(argv[i]), n >= 1 { out.limit = n }
        case "-h", "--help":
            print("""
            usage: photo-snail-app [--list [N]] [--model <name>] [--bare|--hybrid] [--no-downsize]
                                 [--db <path>] [--concurrency <N>] [--sentinel <marker>] [--dry-run]
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(a)\n".utf8))
        }
        i += 1
    }
    return out
}

@main
struct App {
    static func main() async {
        let args = parseArgs(CommandLine.arguments)

        if let n = args.list {
            await runList(n: n)
            return
        }

        var config = QueueRunner.Config()
        config.model = args.model
        config.promptStyle = args.promptStyle
        config.noDownsize = args.noDownsize
        config.concurrency = args.concurrency
        config.sentinel = args.sentinel
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
            FileHandle.standardError.write(Data("ERROR: Photo Library auth \(PhotoLibrary.authStatusLabel(status))\n".utf8))
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
