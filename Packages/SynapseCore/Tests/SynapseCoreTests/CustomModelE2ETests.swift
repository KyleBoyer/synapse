import Foundation
import XCTest
@testable import SynapseCore

/// Adding a model by its Hugging Face link, end to end against the real Hub, in a throwaway store.
/// SYNAPSE_E2E=1 (downloads ~700 MB).
final class CustomModelE2ETests: XCTestCase {
    func testAddDownloadAndChatWithALinkedModel() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let report = try await HFModelInspector.inspect("https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit", token: nil)
        print("[custom] \(report.model) \(report.notes)")
        XCTAssertEqual(report.model.engine, .mlx, "llama runs in-process through MLXLLM")

        let root = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root); Catalog.setCustom([]) }
        try JSONEncoder().encode([String: String]()).write(to: root.appending(path: "manifest.json"))
        Catalog.setCustom([report.model])
        let store = ModelStore(root: root)
        _ = try await store.download(report.model.id, token: nil) { _ in }
        let chat = ChatService(store: store)
        let spec = try XCTUnwrap(Catalog.spec(report.model.id))
        var answer = ""
        for try await e in try await chat.stream(model: spec, messages: [ChatMessage(role: .user, text: "What is the capital of France? Answer with one word.")],
                                                 options: ChatOptions(maxTokens: 10, temperature: 0)) {
            if case .delta(let d) = e { answer += d }
        }
        print("[custom] \(spec.id): \(answer)")
        XCTAssertTrue(answer.lowercased().contains("paris"), answer)
    }

    func testRealReposAreClassified() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let omni = try await HFModelInspector.inspect("LiquidAI/LFM3-Omni-2B", token: nil)
        XCTAssertEqual(omni.model.engine, .mlxvlm)
        do {
            _ = try await HFModelInspector.inspect("bartowski/Llama-3.2-1B-Instruct-GGUF", token: nil)
            XCTFail("GGUF should be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("GGUF"), error.localizedDescription) }
        do {
            _ = try await HFModelInspector.inspect("no-such-org-zz/no-such-model-zz", token: nil)
            XCTFail("missing repo should be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No model named"), error.localizedDescription) }
    }
}
