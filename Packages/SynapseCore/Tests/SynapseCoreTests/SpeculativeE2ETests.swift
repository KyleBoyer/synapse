import XCTest
@testable import SynapseCore

/// Speculative decoding on real models.
/// Run: SYNAPSE_MODELS_DIR=... scripts/with-gpu-lock.sh scripts/test-chat-e2e.sh SpeculativeE2ETests
final class SpeculativeE2ETests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
    }

    private struct Run { var text: String; var usage: ChatUsage; var decodeRate: Double }

    private func run(_ chat: ChatService, _ spec: ModelSpec, _ prompt: String) async throws -> Run {
        var text = "", usage = ChatUsage(promptTokens: 0, completionTokens: 0)
        var first: ContinuousClock.Instant?
        for try await e in try await chat.stream(model: spec, messages: [ChatMessage(role: .user, text: prompt)],
                                                 options: ChatOptions(maxTokens: 160, temperature: 0)) {
            switch e {
            case .delta(let s): if first == nil { first = .now }; text += s
            case .done(_, let u): usage = u
            default: break
            }
        }
        let d = ContinuousClock.now - (first ?? .now)
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return Run(text: text, usage: usage, decodeRate: Double(max(usage.completionTokens - 1, 0)) / max(seconds, 1e-6))
    }

    /// Pure-attention pair, added as custom models into a scratch store (about 2.5 GB, downloaded once).
    func testDraftKeepsGreedyOutputIdentical() async throws {
        let root = URL(fileURLWithPath: "/Volumes/Workspace NVME/SynapseScratch/speculative-models")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: root.appending(path: "manifest.json").path) {
            try JSONEncoder().encode([String: String]()).write(to: root.appending(path: "manifest.json"))
        }
        var custom: [CustomModel] = []
        for repo in ["mlx-community/Llama-3.2-1B-Instruct-4bit", "mlx-community/Llama-3.2-3B-Instruct-4bit"] {
            custom.append(try await HFModelInspector.inspect("https://huggingface.co/\(repo)", token: nil).model)
        }
        Catalog.setCustom(custom)
        let models = custom.map(\.spec)
        defer { Catalog.setCustom([]) }
        let store = ModelStore(root: root)
        for m in models where await store.folder(for: m.id) == nil { _ = try await store.download(m.id, token: nil) { _ in } }
        let chat = ChatService(store: store)
        let (draft, main) = (models[0], models[1])
        let candidates = await chat.draftCandidates(for: main).map(\.id)
        XCTAssertEqual(candidates, [draft.id])

        let prompt = "List the planets of the solar system in order from the Sun, one per line, with one fact about each."
        _ = try await run(chat, main, "hi")   // load and warm up
        _ = try await chat.complete(model: draft, messages: [ChatMessage(role: .user, text: "hi")], options: ChatOptions(maxTokens: 2))
        // Alternate plain and drafted runs so drift (heat, other load) hits both alike.
        var plainRates: [Double] = [], draftedRates: [Double] = []
        var plainText = "", draftedText = ""
        for _ in 0..<3 {
            await chat.setDraftModel(nil, for: main.id)
            let p = try await run(chat, main, prompt)
            XCTAssertFalse(p.usage.drafted)
            await chat.setDraftModel(draft.id, for: main.id)
            let d = try await run(chat, main, prompt)
            XCTAssertTrue(d.usage.drafted)
            plainRates.append(p.decodeRate); draftedRates.append(d.decodeRate)
            plainText = p.text; draftedText = d.text
            XCTAssertEqual(p.text, d.text, "speculative decoding changed greedy output")
        }
        func f(_ v: [Double]) -> String { v.map { String(format: "%.1f", $0) }.joined(separator: ", ") }
        print("[speculative] plain [\(f(plainRates))] tok/s, drafted [\(f(draftedRates))] tok/s, \(plainText.count) chars")
        XCTAssertEqual(plainText, draftedText)
    }

    /// Qwen3.5 is hybrid (linear attention), so it is never offered a draft, and a draft set anyway is ignored.
    func testHybridModelsGetNoDraftAndStillAnswer() async throws {
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let chat = ChatService(store: ModelStore(root: root))
        let main = try await chat.resolve("qwen3.5-2b")
        let none = await chat.draftCandidates(for: main)
        XCTAssertTrue(none.isEmpty)
        await chat.setDraftModel("qwen3.5-0.8b", for: main.id)
        let r = try await run(chat, main, "What is 2 + 2? Reply with only the number.")
        XCTAssertTrue(r.text.contains("4"), r.text)
        XCTAssertFalse(r.usage.drafted)
    }
}
