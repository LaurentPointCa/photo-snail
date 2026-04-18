import XCTest
@testable import PhotoSnailCore

final class SettingsMigrationTests: XCTestCase {

    func testV2Decode_seedsModelConfigsForActiveFamily() throws {
        let v2JSON = """
        {
          "version": 2,
          "model": "gemma4:31b",
          "sentinel": "ai:gemma4-v3",
          "apiProvider": "ollama",
          "ollama": { "baseURL": "http://localhost:11434", "headers": {} },
          "openai": { "baseURL": "http://localhost:9090/v1", "headers": {} },
          "customPrompt": "Describe briefly.",
          "promptLanguage": "fr",
          "autoStartWhenLocked": true
        }
        """
        let data = v2JSON.data(using: .utf8)!
        let s = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(s.model, "gemma4:31b")
        XCTAssertEqual(s.activeFamily, "gemma4")
        XCTAssertEqual(s.sentinel, "ai:gemma4-v3")
        XCTAssertEqual(s.customPrompt, "Describe briefly.")
        XCTAssertEqual(s.promptLanguage, "fr")
        XCTAssertTrue(s.autoStartWhenLocked)

        XCTAssertEqual(s.modelConfigs.count, 1)
        let cfg = try XCTUnwrap(s.modelConfigs["gemma4"])
        XCTAssertEqual(cfg.sentinelVersion, 3)
        XCTAssertNil(cfg.customSentinel)
    }

    func testV2Decode_preservesLongFormSentinelAsCustom() throws {
        // Scenario: user was on an OpenAI model with the OLD long-form sentinel
        // logic (pre-shortFamily). Migration must not silently rewrite the
        // sentinel string that's already in Photos.app metadata.
        let v2JSON = """
        {
          "version": 2,
          "model": "mlx-community/Qwen3.6-35B-A3B-4bit",
          "sentinel": "ai:mlx-community-qwen3-6-35b-a3b-4bit-v1",
          "apiProvider": "openai-compatible",
          "ollama": { "baseURL": "http://localhost:11434", "headers": {} },
          "openai": { "baseURL": "http://host:9090/v1", "headers": {} }
        }
        """
        let data = v2JSON.data(using: .utf8)!
        let s = try JSONDecoder().decode(Settings.self, from: data)

        // Active family becomes the SHORT form going forward.
        XCTAssertEqual(s.activeFamily, "qwen3-6")
        // But the stored sentinel is preserved verbatim as a custom pin so
        // write-backs land on the exact same string already in Photos.app.
        XCTAssertEqual(s.sentinel, "ai:mlx-community-qwen3-6-35b-a3b-4bit-v1")

        let cfg = try XCTUnwrap(s.modelConfigs["qwen3-6"])
        XCTAssertEqual(cfg.customSentinel, "ai:mlx-community-qwen3-6-35b-a3b-4bit-v1")
        XCTAssertEqual(cfg.sentinelVersion, 1)
    }

    func testActiveConfig_swapsWithModel() {
        var s = Settings(
            model: "gemma4:31b",
            modelConfigs: [
                "gemma4": ModelConfig(customPrompt: "prompt for gemma", sentinelVersion: 2),
                "qwen3-6": ModelConfig(customPrompt: "prompt for qwen", sentinelVersion: 1),
            ]
        )
        XCTAssertEqual(s.customPrompt, "prompt for gemma")
        XCTAssertEqual(s.sentinel, "ai:gemma4-v2")

        s.model = "mlx-community/Qwen3.6-35B-A3B-4bit"
        XCTAssertEqual(s.activeFamily, "qwen3-6")
        XCTAssertEqual(s.customPrompt, "prompt for qwen")
        XCTAssertEqual(s.sentinel, "ai:qwen3-6-v1")

        // Switch back — gemma's config must still be there.
        s.model = "gemma4:latest"
        XCTAssertEqual(s.customPrompt, "prompt for gemma")
        XCTAssertEqual(s.sentinel, "ai:gemma4-v2")
    }

    func testSentinelSetter_canonicalFormTracksVersionOnly() {
        var s = Settings(model: "gemma4:31b", modelConfigs: ["gemma4": ModelConfig()])
        s.sentinel = "ai:gemma4-v5"
        XCTAssertEqual(s.modelConfigs["gemma4"]?.sentinelVersion, 5)
        XCTAssertNil(s.modelConfigs["gemma4"]?.customSentinel)
    }

    func testSentinelSetter_nonCanonicalFormPinsAsCustom() {
        var s = Settings(model: "gemma4:31b", modelConfigs: ["gemma4": ModelConfig()])
        s.sentinel = "ai:my-custom-sentinel-v1"
        XCTAssertEqual(s.modelConfigs["gemma4"]?.customSentinel, "ai:my-custom-sentinel-v1")
    }

    func testEncodeRoundTrip_preservesModelConfigs() throws {
        let original = Settings(
            model: "gemma4:31b",
            modelConfigs: [
                "gemma4": ModelConfig(customPrompt: "A", sentinelVersion: 3, promptLanguage: "en"),
                "qwen3-6": ModelConfig(customPrompt: "B", sentinelVersion: 1, promptLanguage: "fr"),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(decoded.modelConfigs.count, 2)
        XCTAssertEqual(decoded.modelConfigs["gemma4"]?.customPrompt, "A")
        XCTAssertEqual(decoded.modelConfigs["gemma4"]?.sentinelVersion, 3)
        XCTAssertEqual(decoded.modelConfigs["qwen3-6"]?.customPrompt, "B")
        XCTAssertEqual(decoded.modelConfigs["qwen3-6"]?.promptLanguage, "fr")
    }

    func testEncodeEmitsLegacyTopLevelFields() throws {
        // Forward-compat: an older build (v2 reader) must still find
        // customPrompt / promptLanguage / sentinel at the top level.
        let s = Settings(
            model: "gemma4:31b",
            modelConfigs: [
                "gemma4": ModelConfig(customPrompt: "hello", sentinelVersion: 4, promptLanguage: "de"),
            ]
        )
        let data = try JSONEncoder().encode(s)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["customPrompt"] as? String, "hello")
        XCTAssertEqual(json["promptLanguage"] as? String, "de")
        XCTAssertEqual(json["sentinel"] as? String, "ai:gemma4-v4")
    }
}
