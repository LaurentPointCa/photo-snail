import XCTest
@testable import PhotoSnailCore

final class SentinelTests: XCTestCase {

    func testContainsAnySentinel_matchesWrittenSentinels() {
        XCTAssertTrue(Sentinel.containsAnySentinel("ai:gemma4-v1"))
        XCTAssertTrue(Sentinel.containsAnySentinel("ai:gemma4-v2"))
        XCTAssertTrue(Sentinel.containsAnySentinel("ai:llama3-2-v7"))
        XCTAssertTrue(Sentinel.containsAnySentinel("ai:llava-v1"))
        XCTAssertTrue(Sentinel.containsAnySentinel("ai:mistral-small-v1"))
    }

    func testContainsAnySentinel_matchesWhenEmbeddedInDescription() {
        let payload = "A sunset over mountains. Tags: landscape, nature, ai:gemma4-v1"
        XCTAssertTrue(Sentinel.containsAnySentinel(payload))

        let multiline = "User's own words.\n\n---\n\nOurs. Tags: foo, ai:gemma4-v3"
        XCTAssertTrue(Sentinel.containsAnySentinel(multiline))
    }

    func testContainsAnySentinel_rejectsPlainText() {
        XCTAssertFalse(Sentinel.containsAnySentinel(""))
        XCTAssertFalse(Sentinel.containsAnySentinel("A user-written photo caption."))
        XCTAssertFalse(Sentinel.containsAnySentinel("Thoughts on ai and ML"))
        XCTAssertFalse(Sentinel.containsAnySentinel("v1 draft"))
        XCTAssertFalse(Sentinel.containsAnySentinel("ai:"))
        XCTAssertFalse(Sentinel.containsAnySentinel("ai:gemma4"))
        XCTAssertFalse(Sentinel.containsAnySentinel("ai:gemma4-v"))
    }

    func testContainsAnySentinel_rejectsUppercaseOrSpaced() {
        XCTAssertFalse(Sentinel.containsAnySentinel("AI:GEMMA4-V1"))
        XCTAssertFalse(Sentinel.containsAnySentinel("ai: gemma4-v1"))
    }
}
