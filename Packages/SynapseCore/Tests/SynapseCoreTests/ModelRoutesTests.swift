import Hummingbird
import HummingbirdTesting
import XCTest
@testable import SynapseCore

private func object(_ b: ByteBuffer) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any])
}

/// The model listings: OpenAI and Anthropic list and retrieve on one path, Anthropic's paging, and LM Studio's list.
final class ModelRoutesTests: XCTestCase {
    private let gguf = CustomModel(repo: "org/Tiny-GGUF", engine: .gguf, displayName: "Tiny-GGUF", approxMB: 800, ramGB: 1,
                                   files: ["Tiny-Q4_K_M.gguf", "mmproj-Tiny-f16.gguf"])

    override func tearDown() { Catalog.setCustom([]) }

    private func makeApp() async throws -> Application<RouterResponder<SynapseContext>> {
        Catalog.setCustom([gguf])
        let store = try TestSupport.store(downloaded: ["parakeet-v3", "qwen3.5-0.8b", gguf.repo])
        let qwen = await store.root.appending(path: "qwen3.5-0.8b")
        try Data(#"{"model_type": "qwen3_5", "text_config": {"max_position_embeddings": 262144}, "quantization": {"bits": 4}}"#.utf8)
            .write(to: qwen.appending(path: "config.json"))
        try Data("{% if tools %}...{% endif %}<think>".utf8).write(to: qwen.appending(path: "chat_template.jinja"))
        try Data("{}".utf8).write(to: qwen.appending(path: "preprocessor_config.json"))
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box,
                             engineFactory: { _, _ in FakeEngine() })
        return Application(router: buildRouter(queue: queue, store: store, settings: box))
    }


    func testListCarriesOpenAIAndAnthropicFieldsAndSynapseFacts() async throws {
        try await self.makeApp().test(.router) { c in
            try await c.execute(uri: "/v1/models", method: .get) {
                let o = try object($0.body)
                let data = try XCTUnwrap(o["data"] as? [[String: Any]])
                XCTAssertEqual(data.map { $0["id"] as? String }, ["org/Tiny-GGUF", "parakeet-v3", "qwen3.5-0.8b"])
                XCTAssertEqual(o["has_more"] as? Bool, false)
                let qwen = try XCTUnwrap(data.last)
                XCTAssertEqual(qwen["object"] as? String, "model")
                XCTAssertEqual(qwen["type"] as? String, "model")
                XCTAssertNotNil(qwen["created"] as? Int)
                XCTAssertNotNil(qwen["created_at"] as? String)
                XCTAssertEqual(qwen["max_input_tokens"] as? Int, 262144)
                let caps = try XCTUnwrap(qwen["capabilities"] as? [String: Any])
                XCTAssertEqual((caps["image_input"] as? [String: Any])?["supported"] as? Bool, true)
                XCTAssertEqual((caps["thinking"] as? [String: Any])?["supported"] as? Bool, true)
                let syn = try XCTUnwrap(qwen["synapse"] as? [String: Any])
                XCTAssertEqual(syn["kind"] as? String, "chat")
                XCTAssertEqual(syn["quantization"] as? String, "4bit")
                XCTAssertEqual(syn["input_modalities"] as? [String], ["text", "image"])
                let parakeet = data[1]
                XCTAssertTrue(parakeet["capabilities"] is NSNull, "only chat models carry Anthropic capabilities")
                XCTAssertEqual((parakeet["synapse"] as? [String: Any])?["kind"] as? String, "transcription")
            }
        }
    }

    func testAnthropicPaging() async throws {
        try await self.makeApp().test(.router) { c in
            try await c.execute(uri: "/v1/models?limit=2", method: .get) {
                let o = try object($0.body)
                XCTAssertEqual((o["data"] as? [[String: Any]])?.count, 2)
                XCTAssertEqual(o["has_more"] as? Bool, true)
                XCTAssertEqual(o["last_id"] as? String, "parakeet-v3")
            }
            try await c.execute(uri: "/v1/models?limit=2&after_id=parakeet-v3", method: .get) {
                let o = try object($0.body)
                XCTAssertEqual((o["data"] as? [[String: Any]])?.map { $0["id"] as? String }, ["qwen3.5-0.8b"])
                XCTAssertEqual(o["has_more"] as? Bool, false)
            }
            try await c.execute(uri: "/v1/models?limit=0", method: .get) { XCTAssertEqual($0.status, .badRequest) }
        }
    }

    func testRetrieveIncludingIdsWithASlash() async throws {
        try await self.makeApp().test(.router) { c in
            try await c.execute(uri: "/v1/models/org/Tiny-GGUF", method: .get) {
                XCTAssertEqual($0.status, .ok)
                let o = try object($0.body)
                XCTAssertEqual(o["id"] as? String, "org/Tiny-GGUF")
                XCTAssertEqual((o["synapse"] as? [String: Any])?["quantization"] as? String, "Q4_K_M")
                XCTAssertEqual((o["synapse"] as? [String: Any])?["input_modalities"] as? [String], ["text", "image"])
            }
            try await c.execute(uri: "/models/qwen3.5-0.8b", method: .get) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/v1/models/org%2FTiny-GGUF", method: .get) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/v1/models/whisper-tiny", method: .get) { XCTAssertEqual($0.status, .notFound) }
        }
    }

    func testLMStudioListsChatAndEmbeddingModels() async throws {
        try await self.makeApp().test(.router) { c in
            try await c.execute(uri: "/api/v1/models", method: .get) {
                let models = try XCTUnwrap(try object($0.body)["models"] as? [[String: Any]])
                XCTAssertEqual(models.map { $0["key"] as? String }, ["org/Tiny-GGUF", "qwen3.5-0.8b"])
                let tiny = models[0]
                XCTAssertEqual(tiny["type"] as? String, "llm")
                XCTAssertEqual(tiny["publisher"] as? String, "org")
                XCTAssertEqual(tiny["format"] as? String, "gguf")
                XCTAssertEqual((tiny["quantization"] as? [String: Any])?["bits_per_weight"] as? Int, 4)
                XCTAssertEqual(tiny["loaded_instances"] as? [String], [])
                let qwen = models[1]
                XCTAssertEqual(((qwen["capabilities"] as? [String: Any])?["reasoning"] as? [String: Any])?["default"] as? String, "off")
                XCTAssertEqual((qwen["capabilities"] as? [String: Any])?["trained_for_tool_use"] as? Bool, true)
            }
        }
    }
}
