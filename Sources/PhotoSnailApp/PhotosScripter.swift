import Foundation

/// Typed AppleScript failures.
enum ScripterError: Error, CustomStringConvertible {
    case compileFailed(String)
    /// Common error codes:
    ///   -1743  errAEEventNotPermitted   (user denied Automation access)
    ///   -1728  errAENoSuchObject        (asset id not found — likely uuid prefix bug)
    ///   -2740  errOSAScriptError        (syntax error in our generated source)
    case executionFailed(code: Int, message: String, briefMessage: String)
    case unexpectedResult(String)

    var description: String {
        switch self {
        case .compileFailed(let msg):
            return "AppleScript compile failed: \(msg)"
        case .executionFailed(let code, let message, let brief):
            var hint = ""
            switch code {
            case -1743:
                hint = " (denied Automation access — System Settings > Privacy & Security > Automation > photo-snail > Photos)"
            case -1728:
                hint = " (no such object — likely the uuid prefix is wrong; did you forget to strip /L0/001?)"
            case -2740:
                hint = " (script syntax error — bug in PhotosScripter)"
            default:
                break
            }
            let visible = brief.isEmpty ? message : brief
            return "AppleScript execution failed [code \(code)]\(hint): \(visible)"
        case .unexpectedResult(let msg):
            return "AppleScript returned unexpected result: \(msg)"
        }
    }
}

/// Thin wrapper around NSAppleScript + Photos.app's scripting dictionary.
///
/// THREADING: NSAppleScript MUST be called from the main thread. AppleEvent
/// replies are dispatched to the main thread's CFRunLoop; calling from any
/// other thread falls back to a Carbon-era WaitNextEvent path (~30 s/call).
/// Wrap callers in `await MainActor.run { ... }`.
enum PhotosScripter {

    // MARK: - Description-only batched round-trip

    struct BatchResult {
        let stepSeconds: [Int]
        static let stepLabels = [
            "resolve_id_to_local_var",
            "read_pre_description",
            "write_description",
            "read_post_description",
        ]
        let preDescription: String
        let postDescription: String
        let totalWallMs: Double
        let scriptSource: String
    }

    /// Pin asset, read pre-description, write description, read post-description
    /// — all inside one `tell application "Photos"` block.
    ///
    /// The description payload carries: prose + embedded tags + sentinel.
    /// MUST be called via `await MainActor.run { ... }`.
    static func runBatch(uuid: String, descriptionPayload: String) throws -> BatchResult {
        let source = """
        tell application "Photos"
            try
                set t0 to (current date)
                set the_item to media item id "\(escape(uuid))"
                set t1 to (current date)

                set preDesc to description of the_item
                if preDesc is missing value then set preDesc to ""
                set t2 to (current date)

                set description of the_item to "\(escape(descriptionPayload))"
                set t3 to (current date)

                set postDesc to description of the_item
                if postDesc is missing value then set postDesc to ""
                set t4 to (current date)

                set timings to ((t1 - t0) as text) & "|" & ((t2 - t1) as text) & "|" & ((t3 - t2) as text) & "|" & ((t4 - t3) as text)

                return {timings, preDesc, postDesc}
            on error errMsg number errNum
                return {"ERROR", errMsg, (errNum as text)}
            end try
        end tell
        """

        let (desc, ms) = try runScript(source)
        let items = descriptorToStringArray(desc)
        guard items.count >= 3 else {
            throw ScripterError.unexpectedResult("expected 3-item list, got \(items.count) items")
        }
        if items[0] == "ERROR" {
            let code = items.count > 2 ? (Int(items[2]) ?? 0) : 0
            throw ScripterError.executionFailed(code: code, message: items[1], briefMessage: "")
        }

        let timings = items[0].split(separator: "|").compactMap { Int($0) }
        guard timings.count == 4 else {
            throw ScripterError.unexpectedResult("expected 4 timings, got \(timings.count): \(items[0])")
        }

        return BatchResult(
            stepSeconds: timings,
            preDescription: items[1],
            postDescription: items[2],
            totalWallMs: ms,
            scriptSource: source
        )
    }

    // MARK: - Sentinel filter via description text

    /// Return media-item ids whose description contains the given marker.
    /// Used to discover already-processed assets on first run (sentinel bootstrap).
    static func findAssetsByDescriptionMarker(_ marker: String) throws -> ([String], Double) {
        let source = """
        tell application "Photos"
            set matchingItems to (every media item whose description contains "\(escape(marker))")
            set resultIds to {}
            repeat with mi in matchingItems
                set end of resultIds to id of mi
            end repeat
            return resultIds
        end tell
        """
        let (desc, ms) = try runScript(source)
        return (descriptorToStringArray(desc), ms)
    }

    // MARK: - Internals

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c == "\\" { out.append("\\\\") }
            else if c == "\"" { out.append("\\\"") }
            else { out.append(c) }
        }
        return out
    }

    private static func descriptorToStringArray(_ desc: NSAppleEventDescriptor) -> [String] {
        let n = desc.numberOfItems
        guard n > 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 1...n {
            if let item = desc.atIndex(i), let s = item.stringValue {
                out.append(s)
            }
        }
        return out
    }

    private static func runScript(_ source: String) throws -> (NSAppleEventDescriptor, Double) {
        guard let script = NSAppleScript(source: source) else {
            throw ScripterError.compileFailed("NSAppleScript(source:) returned nil")
        }
        var errorInfo: NSDictionary?
        let start = DispatchTime.now()
        let result = script.executeAndReturnError(&errorInfo)
        let end = DispatchTime.now()
        let elapsedMs = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        if let info = errorInfo {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (info[NSAppleScript.errorMessage] as? String) ?? "(no message)"
            let brief = (info[NSAppleScript.errorBriefMessage] as? String) ?? ""
            throw ScripterError.executionFailed(code: code, message: message, briefMessage: brief)
        }
        return (result, elapsedMs)
    }
}
