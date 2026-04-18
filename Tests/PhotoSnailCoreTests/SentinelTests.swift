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

    // MARK: - shortFamily

    func testShortFamily_defersToFamilyForOllamaTags() {
        XCTAssertEqual(Sentinel.shortFamily(of: "gemma4:31b"), "gemma4")
        XCTAssertEqual(Sentinel.shortFamily(of: "gemma4:latest"), "gemma4")
        XCTAssertEqual(Sentinel.shortFamily(of: "llava:13b"), "llava")
        XCTAssertEqual(Sentinel.shortFamily(of: "mistral-small:3b"), "mistral-small")
        XCTAssertEqual(Sentinel.shortFamily(of: "llama3.2:latest"), "llama3-2")
    }

    func testShortFamily_stripsOrgPrefix() {
        XCTAssertEqual(Sentinel.shortFamily(of: "mlx-community/Qwen3.6-35B-A3B-4bit"), "qwen3-6")
        XCTAssertEqual(Sentinel.shortFamily(of: "TheBloke/Llama-3.2-7B-Instruct-GPTQ"), "llama-3-2")
        XCTAssertEqual(Sentinel.shortFamily(of: "mlx-community/Qwen2-VL-7B-Instruct"), "qwen2-vl")
    }

    func testShortFamily_stripsQuantAndSizeSuffixes() {
        XCTAssertEqual(Sentinel.shortFamily(of: "Qwen-7B-Chat-q4_K_M"), "qwen")
        XCTAssertEqual(Sentinel.shortFamily(of: "Mistral-7B-Instruct-v0.2-AWQ"), "mistral-7b-instruct-v0-2")
        // Version tails like v0.2 don't match our suffix list — preserved verbatim.
        XCTAssertEqual(Sentinel.shortFamily(of: "llava-next-8b-mlx"), "llava-next")
    }

    func testShortFamily_handlesPlainName() {
        XCTAssertEqual(Sentinel.shortFamily(of: "gemma"), "gemma")
        XCTAssertEqual(Sentinel.shortFamily(of: "my.custom.model"), "my-custom-model")
    }

    func testPropose_usesShortFamilyForOpenAIIds() {
        let proposed = Sentinel.propose(
            forModel: "mlx-community/Qwen3.6-35B-A3B-4bit",
            currentSentinel: "ai:gemma4-v1"
        )
        XCTAssertEqual(proposed, "ai:qwen3-6-v1")
    }

    func testPropose_acceptsLongFormAsSameFamily() {
        // Users with pre-existing long-form sentinels from the old propose() logic
        // should NOT be prompted to migrate when staying on the same model.
        let currentLong = "ai:mlx-community-qwen3-6-35b-a3b-4bit-v1"
        let proposed = Sentinel.propose(
            forModel: "mlx-community/Qwen3.6-35B-A3B-4bit",
            currentSentinel: currentLong
        )
        XCTAssertNil(proposed)
    }
}
