import XCTest
@testable import PhotoSnailCore

final class CaptionParserTests: XCTestCase {

    // MARK: - JSON path (v20 prompt)

    func testParse_plainJSON() {
        let raw = #"""
        {"description":"A red car parked on a street.","tags":["car","street","outdoor"]}
        """#
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "A red car parked on a street.")
        XCTAssertEqual(p.tags, ["car", "street", "outdoor"])
    }

    func testParse_JSONWithWhitespace() {
        let raw = """
        {
          "description": "Two cats at a glass door.",
          "tags": ["cats", "glass door", "indoor"]
        }
        """
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "Two cats at a glass door.")
        XCTAssertEqual(p.tags, ["cats", "glass door", "indoor"])
    }

    func testParse_JSONWithPreamble() {
        // Tolerate the "Here's the JSON:" preamble a model might emit despite instructions.
        let raw = #"""
        Here is the JSON:
        {"description":"Birthday cake with candles.","tags":["cake","candles","birthday"]}
        """#
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "Birthday cake with candles.")
        XCTAssertEqual(p.tags, ["cake", "candles", "birthday"])
    }

    func testParse_JSONInMarkdownFence() {
        let raw = """
        ```json
        {"description":"A succulent with exposed roots.","tags":["succulent","roots","repotting"]}
        ```
        """
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "A succulent with exposed roots.")
        XCTAssertEqual(p.tags, ["succulent", "roots", "repotting"])
    }

    func testParse_JSONTagsLowercasedAndTrimmed() {
        let raw = #"""
        {"description":"x","tags":["  Kitchen  ","Christmas Tree","BMW M"]}
        """#
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.tags, ["kitchen", "christmas tree", "bmw m"])
    }

    func testParse_JSONMissingTagsTreatedAsEmpty() {
        let raw = #"""
        {"description":"just a description"}
        """#
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "just a description")
        XCTAssertEqual(p.tags, [])
    }

    func testParse_JSONWithEscapedQuotes() {
        // v20 prompt instructs the model to quote brand text inside the description.
        let raw = #"""
        {"description":"A caliper with an \"M\" logo.","tags":["caliper","bmw m"]}
        """#
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, #"A caliper with an "M" logo."#)
        XCTAssertEqual(p.tags, ["caliper", "bmw m"])
    }

    func testParse_JSONWithBracesInString() {
        // Balanced-brace scan must not be fooled by a `{` or `}` inside a string.
        let raw = #"""
        {"description":"A painted smiley {:)} on a wall.","tags":["graffiti"]}
        """#
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "A painted smiley {:)} on a wall.")
        XCTAssertEqual(p.tags, ["graffiti"])
    }

    // MARK: - Colon-header fallback (gemma4 default)

    func testParse_descriptionAndTags() {
        let raw = """
        DESCRIPTION: A red car on a sunny street.
        TAGS: car, red, street, sunny
        """
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "A red car on a sunny street.")
        XCTAssertEqual(p.tags, ["car", "red", "street", "sunny"])
    }

    func testParse_markdownBoldStripped() {
        let raw = """
        **DESCRIPTION:** A cat on a windowsill.
        **TAGS:** cat, window, indoor
        """
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "A cat on a windowsill.")
        XCTAssertEqual(p.tags, ["cat", "window", "indoor"])
    }

    func testParse_caseInsensitive() {
        let raw = """
        Description: a plant on a shelf.
        Tags: plant, shelf, green
        """
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "a plant on a shelf.")
        XCTAssertEqual(p.tags, ["plant", "shelf", "green"])
    }

    func testParse_tagsSemicolonSeparated() {
        let raw = "DESCRIPTION: x\nTAGS: a; b; c"
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.tags, ["a", "b", "c"])
    }

    // MARK: - Fallback behavior

    func testParse_malformedJSONFallsBackToColonHeaders() {
        // Missing closing brace → JSON parse fails; colon-header path picks up.
        let raw = """
        { "description": broken
        DESCRIPTION: A red car.
        TAGS: car, red
        """
        let p = CaptionParser.parse(raw)
        XCTAssertEqual(p.description, "A red car.")
        XCTAssertEqual(p.tags, ["car", "red"])
    }

    func testParse_emptyInput() {
        let p = CaptionParser.parse("")
        XCTAssertEqual(p.description, "")
        XCTAssertEqual(p.tags, [])
    }

    func testParse_noMarkersAndNoJSON() {
        let p = CaptionParser.parse("just a freeform description")
        XCTAssertEqual(p.description, "just a freeform description")
        XCTAssertEqual(p.tags, [])
    }
}
