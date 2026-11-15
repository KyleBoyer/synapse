import XCTest
@testable import SynapseCore

/// Real Qwen3.5 0.8B inference. Needs SYNAPSE_E2E=1 and an MLX metallib: run scripts/test-chat-e2e.sh.
final class ChatE2ETests: XCTestCase {
    static let storeRoot = FileManager.default.temporaryDirectory.appending(path: "synapse-e2e-models")

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
    }

    private func service() async throws -> (ChatService, ModelSpec) {
        let store = ModelStore(root: Self.storeRoot)
        _ = try await store.download("qwen3.5-0.8b") { _ in }
        let chat = ChatService(store: store)
        return (chat, try await chat.resolve("qwen3.5-0.8b"))
    }

    func testTextAnswer() async throws {
        let (chat, spec) = try await service()
        let r = try await chat.complete(model: spec, messages: [
            ChatMessage(role: .user, text: "What is 2 + 2? Reply with only the number."),
        ], options: ChatOptions(maxTokens: 20, temperature: 0))
        print("[text] \(r.text) \(r.usage)")
        XCTAssertTrue(r.text.contains("4"), r.text)
        XCTAssertFalse(r.text.contains("<think>"))
        XCTAssertGreaterThan(r.usage.promptTokens, 0)
        XCTAssertGreaterThan(r.usage.completionTokens, 0)
    }

    func testVisionNamesAnimals() async throws {
        let (chat, spec) = try await service()
        for (file, animal) in [("zebra.jpg", "zebra"), ("penguin.png", "penguin")] {
            let image = try Data(contentsOf: TestSupport.fixture(file))
            let r = try await chat.complete(model: spec, messages: [
                ChatMessage(role: .user, text: "What animal is in this picture? Answer in one word.", images: [image]),
            ], options: ChatOptions(maxTokens: 20, temperature: 0))
            print("[vision \(file)] \(r.text)")
            XCTAssertTrue(r.text.lowercased().contains(animal), "\(file): \(r.text)")
        }
    }

    func testMaxTokensReportsLength() async throws {
        let (chat, spec) = try await service()
        let r = try await chat.complete(model: spec, messages: [
            ChatMessage(role: .user, text: "Count from 1 to 100, separated by commas."),
        ], options: ChatOptions(maxTokens: 8, temperature: 0))
        XCTAssertEqual(r.finishReason, "length")
        XCTAssertEqual(r.usage.completionTokens, 8)
    }
}
