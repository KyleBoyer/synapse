import Synchronization
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
        let updates = Mutex(0)
        _ = try await store.download(report.model.id, token: nil) { _ in updates.withLock { $0 += 1 } }
        // One 700 MB weights file: progress must move while it downloads, not jump at the end.
        XCTAssertGreaterThan(updates.withLock { $0 }, 20)
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

    /// A GGUF model end to end: inspect, download only the chosen quantization, chat through llama.cpp.
    func testGGUFModelDownloadsAndChats() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let report = try await HFModelInspector.inspect("https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF", token: nil)
        print("[gguf] \(report.model.files ?? []) \(report.model.approxMB) MB; \(report.ggufChoices.count) quantizations")
        let root = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root); Catalog.setCustom([]) }
        try JSONEncoder().encode([String: String]()).write(to: root.appending(path: "manifest.json"))
        Catalog.setCustom([report.model])
        let store = ModelStore(root: root)
        let folder = try await store.download(report.model.id, token: nil) { _ in }
        let ggufFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".gguf") }
        XCTAssertEqual(ggufFiles, ["Llama-3.2-1B-Instruct-Q4_K_M.gguf"], "only the chosen quantization is downloaded")
        let models = ModelManager()
        let chat = ChatService(store: store, models: models)
        let spec = try XCTUnwrap(Catalog.spec(report.model.id))
        var answer = ""
        var progress: [ChatProgress] = []
        let start = Date()
        // A long prompt, so llama.cpp reports progress mid-prompt (it processes 2048 tokens per batch).
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 400)
        for try await e in try await chat.stream(model: spec, messages: [ChatMessage(role: .user, text: filler + "\nWhat is the capital of France? Answer with one word.")],
                                                 options: ChatOptions(maxTokens: 10, temperature: 0)) {
            switch e {
            case .delta(let d): answer += d
            case .progress(let p): progress.append(p)
            default: break
            }
        }
        print(String(format: "[gguf] %.1f s: %@", Date().timeIntervalSince(start), answer))
        print("[gguf] progress: \(progress)")
        XCTAssertTrue(answer.lowercased().contains("paris"), answer)
        XCTAssertEqual(progress.first, .loadStarted)
        guard case .loaded = progress[1] else { return XCTFail("\(progress)") }
        XCTAssertEqual(progress[2], .promptStarted)
        XCTAssertEqual(progress.last, .promptDone)
        let fractions = progress.compactMap { if case .prompt(let f) = $0 { f } else { nil } }
        XCTAssertTrue(fractions.contains { $0 > 0 && $0 < 1 }, "a fraction mid-prompt: \(fractions)")
        XCTAssertEqual(fractions, fractions.sorted())
        try await Task.sleep(for: .milliseconds(200))
        await models.unloadAllIdle()
    }

    func testRealReposAreClassified() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let omni = try await HFModelInspector.inspect("LiquidAI/LFM3-Omni-2B", token: nil)
        XCTAssertEqual(omni.model.engine, .mlxvlm)
        let gguf = try await HFModelInspector.inspect("bartowski/Llama-3.2-1B-Instruct-GGUF", token: nil)
        XCTAssertEqual(gguf.model.engine, .gguf)
        XCTAssertEqual(gguf.model.files?.first, "Llama-3.2-1B-Instruct-Q4_K_M.gguf")
        do {
            _ = try await HFModelInspector.inspect("no-such-org-zz/no-such-model-zz", token: nil)
            XCTFail("missing repo should be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No model named"), error.localizedDescription) }
    }
}
