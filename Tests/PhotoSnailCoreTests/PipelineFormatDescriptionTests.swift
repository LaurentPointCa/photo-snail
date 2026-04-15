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

    func testExistingWithSentinel_overwritesCleanly() {
        let stale = "Old text. Tags: foo, bar, ai:gemma4-v1"
        let out = Pipeline.formatDescription(
            description: "A red car",
            tags: ["car"],
            sentinel: "ai:gemma4-v2",
            existingDescription: stale
        )
        XCTAssertEqual(out, "A red car. Tags: car, ai:gemma4-v2")
    }

    func testExistingUserTextPlusOurs_stillPreservedByContainsCheck() {
        // A previously preserved description already has our sentinel buried
        // after the separator. Treat it as ours and overwrite — user text
        // is intentionally NOT re-preserved to avoid ever-growing descriptions.
        let combined = "User original text\n\n---\n\nOurs. Tags: foo, ai:gemma4-v1"
        let out = Pipeline.formatDescription(
            description: "New prose",
            tags: ["new"],
            sentinel: "ai:gemma4-v2",
            existingDescription: combined
        )
        XCTAssertEqual(out, "New prose. Tags: new, ai:gemma4-v2")
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
}
