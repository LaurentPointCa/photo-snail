import Foundation

/// Polls the GitHub Releases API for the canonical `photo-snail` repo and
/// surfaces new stable releases through an in-app sheet. MVP only — no
/// auto-download, no delta updates, no signature verification. When a
/// new version is detected the user gets release notes + a button that
/// opens the GitHub release page in their browser so they can grab the
/// zip themselves.
///
/// Replace with Sparkle later; delete this module when that lands.
@Observable
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    // MARK: - Configuration

    /// Owner/repo coordinate used to build the API + release-page URLs.
    /// Matches the "GitHub" link in the About panel.
    private let owner = "LaurentPointCa"
    private let repo = "photo-snail"

    /// Minimum gap between automatic checks. Hitting the API once a day is
    /// well inside GitHub's 60 req/hr unauthenticated budget even if the
    /// app is launched dozens of times.
    private let autoCheckInterval: TimeInterval = 60 * 60 * 24

    private let userDefaultsLastCheckedKey = "photo-snail.lastUpdateCheck"
    private let userDefaultsSkippedKey = "photo-snail.skippedUpdateVersions"

    // MARK: - Types

    struct Release: Decodable, Equatable {
        let tagName: String
        let name: String?
        let body: String
        let htmlUrl: URL
        let publishedAt: Date?
        let prerelease: Bool
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlUrl = "html_url"
            case publishedAt = "published_at"
            case prerelease
            case draft
        }

        /// Short display name for the sheet title. Falls back to tag when
        /// GitHub hasn't been given an explicit release name.
        var displayName: String {
            if let name, !name.isEmpty { return name }
            return tagName
        }
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(Release)
        case failed(String)
    }

    // MARK: - Observed state

    private(set) var status: Status = .idle

    /// True when the shown sheet should be presented. Decoupled from
    /// `status` so the user can dismiss the sheet ("Remind me later")
    /// while keeping `.updateAvailable` for the status-bar dot.
    var isSheetPresented: Bool = false

    /// Feedback for the "Check for Updates…" menu path. Non-nil whenever
    /// the last *manual* check should surface a confirmation alert —
    /// either "you're on the latest" or "check failed: <reason>". The
    /// update-available case is handled by the sheet instead, so this
    /// stays nil in that branch.
    enum ManualOutcome: Equatable {
        case upToDate(version: String?)
        case failed(reason: String)
    }
    var manualCheckOutcome: ManualOutcome?

    /// Exposed so the status-bar indicator can light up without dragging
    /// the sheet open. `updateAvailable` → true, anything else → false.
    var hasUpdateAvailable: Bool {
        if case .updateAvailable = status { return true }
        return false
    }

    /// The release behind `hasUpdateAvailable`, for the status-bar tooltip.
    var availableRelease: Release? {
        if case .updateAvailable(let r) = status { return r }
        return nil
    }

    /// Clean semver tag for display in the status bar (e.g. "v0.1.5").
    /// Mirrors `currentReleaseTag()` but public so views can show it. Nil
    /// on unparseable/dev builds so callers can fall back gracefully.
    var currentDisplayVersion: String? { currentReleaseTag() }

    /// GitHub URL for the currently-running version's release page.
    /// Opened from the status bar when the user clicks the "current
    /// version" chip. Nil if we don't have a parseable tag.
    var currentReleaseURL: URL? {
        guard let tag = currentReleaseTag() else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)")
    }

    /// Main repo URL — used by the "View on GitHub" button in the
    /// up-to-date confirmation alert.
    var repoURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)")!
    }

    /// Releases index page on GitHub. Used as the "View on GitHub"
    /// fallback for the up-to-date alert since that's where users go
    /// when they want to see all versions.
    var releasesURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }

    // MARK: - Public entry points

    /// Called at app launch. Runs the check only if the last successful
    /// check was more than `autoCheckInterval` ago. Silent on failure.
    func checkIfNeeded() async {
        let last = UserDefaults.standard.object(forKey: userDefaultsLastCheckedKey) as? Date
        if let last, Date().timeIntervalSince(last) < autoCheckInterval { return }
        await check(forced: false)
    }

    /// Triggered by the "Check for Updates…" menu item. Always hits the
    /// API and always surfaces the result (including "you're up to date"
    /// so the user sees something happened). Skip-list is ignored.
    func checkNow() async {
        await check(forced: true)
    }

    /// Permanently dismiss a version. Sheet won't auto-present for it
    /// again; the status-bar dot also goes away until a newer release is
    /// published.
    func skip(_ release: Release) {
        var set = loadSkipped()
        set.insert(release.tagName)
        saveSkipped(set)
        status = .upToDate
        isSheetPresented = false
    }

    /// "Remind me later" path: dismiss the sheet but keep the state so
    /// the status-bar dot remains and the next launch re-presents the
    /// sheet (subject to the 24-hour auto-check gate).
    func dismissSheet() {
        isSheetPresented = false
    }

    // MARK: - Core

    private func check(forced: Bool) async {
        // Dev builds (N commits past a tag, or with -dirty, or "unknown")
        // have no clean semantic version to compare against. Silently
        // skip — the dev knows what they're running.
        guard let currentTag = currentReleaseTag() else {
            if forced {
                let reason = "Running a development build — no release version to compare."
                status = .failed(reason)
                manualCheckOutcome = .failed(reason: reason)
            }
            return
        }

        status = .checking

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let release: Release
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let reason = "GitHub returned HTTP \(http.statusCode)"
                status = .failed(reason)
                if forced { manualCheckOutcome = .failed(reason: reason) }
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            release = try decoder.decode(Release.self, from: data)
        } catch {
            status = .failed(error.localizedDescription)
            if forced { manualCheckOutcome = .failed(reason: error.localizedDescription) }
            return
        }

        UserDefaults.standard.set(Date(), forKey: userDefaultsLastCheckedKey)

        if release.draft || release.prerelease {
            // `/releases/latest` excludes drafts/prereleases by default,
            // but guard anyway in case the endpoint contract ever changes.
            status = .upToDate
            if forced { manualCheckOutcome = .upToDate(version: currentTag) }
            return
        }

        let skipped = loadSkipped()
        if !forced && skipped.contains(release.tagName) {
            // User said "Skip this version" previously — honor it for
            // automatic checks. Manual "Check for Updates…" overrides.
            status = .upToDate
            return
        }

        switch compareVersions(current: currentTag, remote: release.tagName) {
        case .orderedAscending:
            status = .updateAvailable(release)
            isSheetPresented = true
            // No manualCheckOutcome — the sheet is the feedback.
        case .orderedSame, .orderedDescending:
            status = .upToDate
            if forced { manualCheckOutcome = .upToDate(version: currentTag) }
        }
    }

    /// Clears the manual-check confirmation so the alert goes away.
    func dismissManualOutcome() {
        manualCheckOutcome = nil
    }

    // MARK: - Version helpers

    /// Source of truth for the running version. Priority:
    /// 1. `PHOTO_SNAIL_FAKE_CURRENT` env var — test-only override so we
    ///    can demo the "update available" path without publishing a new
    ///    release. Launch with e.g.
    ///    `PHOTO_SNAIL_FAKE_CURRENT=v0.0.1 PhotoSnail.app/Contents/MacOS/PhotoSnail`.
    /// 2. `PhotoSnailGitVersion` from Info.plist, written by `bundle-gui.sh`
    ///    from `git describe --tags --dirty`. Dev builds like
    ///    `v0.1.5-3-gabc1234` or `...-dirty` are accepted — we strip to
    ///    the leading semver so someone running a few commits past a
    ///    release still gets notified when the NEXT release lands.
    ///
    /// Returns `nil` only when there's no parseable semver to compare
    /// against (e.g. `git describe` returned just a commit hash).
    private func currentReleaseTag() -> String? {
        if let override = ProcessInfo.processInfo.environment["PHOTO_SNAIL_FAKE_CURRENT"],
           !override.isEmpty {
            return extractSemverPrefix(override)
        }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PhotoSnailGitVersion") as? String,
              !raw.isEmpty,
              raw != "unknown" else { return nil }
        return extractSemverPrefix(raw)
    }

    /// Pulls the leading `vX.Y[.Z]` out of a `git describe`-style tag. Any
    /// trailing `-N-g<sha>` or `-dirty` suffix is discarded. Returns `nil`
    /// if the string doesn't start with a parseable semver.
    private func extractSemverPrefix(_ raw: String) -> String? {
        let pattern = #"^v?\d+\.\d+(\.\d+)?"#
        guard let range = raw.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(raw[range])
    }

    /// Numeric three-part compare on `v`-prefixed semver tags. Missing
    /// patch is treated as 0 so `v0.1` ≡ `v0.1.0`. Unparseable → ordered
    /// same so we never nag on malformed data.
    private func compareVersions(current: String, remote: String) -> ComparisonResult {
        let cur = parseVersion(current)
        let rem = parseVersion(remote)
        guard cur.count == 3, rem.count == 3 else { return .orderedSame }
        for i in 0..<3 {
            if rem[i] > cur[i] { return .orderedAscending }
            if rem[i] < cur[i] { return .orderedDescending }
        }
        return .orderedSame
    }

    private func parseVersion(_ tag: String) -> [Int] {
        var s = tag
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        switch parts.count {
        case 0, 1: return []           // too short, treat as unparseable
        case 2: return parts + [0]     // missing patch
        default: return Array(parts.prefix(3))
        }
    }

    // MARK: - Skip-list persistence

    private func loadSkipped() -> Set<String> {
        guard let arr = UserDefaults.standard.array(forKey: userDefaultsSkippedKey) as? [String] else {
            return []
        }
        return Set(arr)
    }

    private func saveSkipped(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: userDefaultsSkippedKey)
    }

    private init() {}
}
