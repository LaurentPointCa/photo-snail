import XCTest
@testable import PhotoSnailCore

final class PipelineFormatDescriptionTests: XCTestCase {

    func testBlankExistingDescription_writesCleanPayload() {
        let out = Pipeline.formatDescription(
            description: "A red car",
            tags: ["car", "vehicle"],
            sentinel: "ai:gemma4-v1",
            existingDescription: ""
        )
        XCTAssertEqual(out, "A red car. Tags: car, vehicle, ai:gemma4-v1")
    }

    func testNilExistingDescription_writesCleanPayload() {
        let out = Pipeline.formatDescription(
            description: "A red car",
            tags: ["car"],
            sentinel: "ai:gemma4-v1",
            existingDescription: nil
        )
        XCTAssertEqual(out, "A red car. Tags: car, ai:gemma4-v1")
    }

    func testWhitespaceOnlyExistingDescription_writesCleanPayload() {
        let out = Pipeline.formatDescription(
            description: "A red car",
            tags: ["car"],
            sentinel: "ai:gemma4-v1",
            existingDescription: "   \n  \t  "
        )
        XCTAssertEqual(out, "A red car. Tags: car, ai:gemma4-v1")
    }

    func testExistingWithoutSentinel_preservesUserText() {
        let user = "Birthday dinner with grandma"
        let out = Pipeline.formatDescription(
            description: "Two people at a dining table",
            tags: ["people", "indoor"],
            sentinel: "ai:gemma4-v1",
            existingDescription: user
        )
        XCTAssertEqual(
            out,
            "Birthday dinner with grandma\n\n---\n\nTwo people at a dining table. Tags: people, indoor, ai:gemma4-v1"
        )
    }

    func testExistingPureOurs_overwritesCleanly() {
        // Asset we wrote on a previous pass, no user prefix ever. On
        // reprocess the user prefix is empty so we emit just our new
        // payload — no orphan separator, no accumulation.
        let stale = "Old text. Tags: foo, bar, ai:gemma4-v1"
        let out = Pipeline.formatDescription(
            description: "A red car",
            tags: ["car"],
            sentinel: "ai:gemma4-v2",
            existingDescription: stale
        )
        XCTAssertEqual(out, "A red car. Tags: car, ai:gemma4-v2")
    }

    func testReprocess_preservesUserTextAndReplacesOurPayload() {
        // The bug we're fixing: on a second touch, the sentinel is already
        // present, so the old code overwrote the whole description
        // (including the user's preserved prefix). The fix splits on the
        // separator, finds the segment containing the sentinel, and replaces
        // ONLY that segment — keeping the user's original text intact across
        // any number of reprocesses.
        let combined = "User original text\n\n---\n\nOurs. Tags: foo, ai:gemma4-v1"
        let out = Pipeline.formatDescription(
            description: "New prose",
            tags: ["new"],
            sentinel: "ai:gemma4-v2",
            existingDescription: combined
        )
        XCTAssertEqual(
            out,
            "User original text\n\n---\n\nNew prose. Tags: new, ai:gemma4-v2"
        )
    }

    func testMultipleReprocesses_dontAccumulate() {
        // Run three reprocesses back-to-back. The user prefix stays the
        // same; only our segment is replaced each time. A regression here
        // (e.g. appending instead of replacing) would show up as ballooning
        // output length across iterations.
        var desc: String? = "Family Christmas 2019"
        for (i, sentinel) in ["ai:gemma4-v1", "ai:gemma4-v2", "ai:gemma4-v3"].enumerated() {
            desc = Pipeline.formatDescription(
                description: "Prose \(i)",
                tags: ["tag\(i)"],
                sentinel: sentinel,
                existingDescription: desc
            )
        }
        XCTAssertEqual(
            desc,
            "Family Christmas 2019\n\n---\n\nProse 2. Tags: tag2, ai:gemma4-v3"
        )
    }

    func testUserDeletedSentinel_treatedAsFreshUserText() {
        // User manually edited the description in Photos.app and removed
        // the sentinel line. Next reprocess treats the whole remaining
        // text as user-authored and appends our fresh payload — we don't
        // try to be clever about detecting our own phrasing heuristically.
        let edited = "User original text\n\n---\n\nEdited prose no sentinel"
        let out = Pipeline.formatDescription(
            description: "New prose",
            tags: ["new"],
            sentinel: "ai:gemma4-v2",
            existingDescription: edited
        )
        XCTAssertEqual(
            out,
            "User original text\n\n---\n\nEdited prose no sentinel\n\n---\n\nNew prose. Tags: new, ai:gemma4-v2"
        )
    }

    func testMultipleSeparatorsInUserPrefix_allSurvive() {
        // If the user's own prose happens to use the `\n\n---\n\n` pattern
        // (e.g. a markdown-style divider in their notes), every separator
        // BEFORE our sentinel-bearing segment is preserved verbatim.
        let combined = "Part A\n\n---\n\nPart B\n\n---\n\nOurs. Tags: foo, ai:gemma4-v1"
        let out = Pipeline.formatDescription(
            description: "Fresh",
            tags: ["t"],
            sentinel: "ai:gemma4-v2",
            existingDescription: combined
        )
        XCTAssertEqual(
            out,
            "Part A\n\n---\n\nPart B\n\n---\n\nFresh. Tags: t, ai:gemma4-v2"
        )
    }

    func testSentinelAlreadyInTags_notDuplicated() {
        let out = Pipeline.formatDescription(
            description: "A red car",
            tags: ["car", "ai:gemma4-v1"],
            sentinel: "ai:gemma4-v1",
            existingDescription: nil
        )
        XCTAssertEqual(out, "A red car. Tags: car, ai:gemma4-v1")
    }

    // MARK: - splitExistingDescription

    func testSplit_noSentinel_returnsWholeTextAsUserPrefix() {
        let (prefix, hasPayload) = Pipeline.splitExistingDescription("User wrote this only.")
        XCTAssertEqual(prefix, "User wrote this only.")
        XCTAssertFalse(hasPayload)
    }

    func testSplit_pureOurs_returnsEmptyPrefix() {
        let (prefix, hasPayload) = Pipeline.splitExistingDescription(
            "Ours. Tags: foo, ai:gemma4-v1"
        )
        XCTAssertEqual(prefix, "")
        XCTAssertTrue(hasPayload)
    }

    func testSplit_userPlusOurs_splitsOnLastSeparator() {
        let (prefix, hasPayload) = Pipeline.splitExistingDescription(
            "User text\n\n---\n\nOurs. Tags: foo, ai:gemma4-v1"
        )
        XCTAssertEqual(prefix, "User text")
        XCTAssertTrue(hasPayload)
    }

    func testSplit_multipleSeparators_preservesAllBeforeSentinel() {
        let (prefix, hasPayload) = Pipeline.splitExistingDescription(
            "Part A\n\n---\n\nPart B\n\n---\n\nOurs. Tags: t, ai:gemma4-v1"
        )
        XCTAssertEqual(prefix, "Part A\n\n---\n\nPart B")
        XCTAssertTrue(hasPayload)
    }
}
