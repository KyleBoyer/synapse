import XCTest
@testable import SynapseCore

/// The prompt cache on real Qwen3.5 0.8B (a hybrid model whose cache cannot be rewound).
/// Run: SYNAPSE_MODELS_DIR=... scripts/with-gpu-lock.sh scripts/test-chat-e2e.sh PromptCacheE2ETests
final class PromptCacheE2ETests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
    }

    private func service() async throws -> (ChatService, ModelSpec) {
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let chat = ChatService(store: ModelStore(root: root))
        return (chat, try await chat.resolve("qwen3.5-0.8b"))
    }

    /// About 3k tokens of system prompt, so prefill time is measurable.
    private let system = (1...120).map { "Rule \($0): answer briefly, stay on topic, and never mention rule numbers." }.joined(separator: "\n")
    private let questions = ["Name a primary color. One word.", "Name another one. One word.", "Which of the two is warmer? One word."]

    private struct Turn { var text: String; var usage: ChatUsage; var firstToken: Double }

    /// Runs the three turns, feeding each reply back as history. `cold` empties the cache before every request.
    private func conversation(_ chat: ChatService, _ spec: ModelSpec, cold: Bool) async throws -> [Turn] {
        var messages = [ChatMessage(role: .system, text: system)]
        var turns: [Turn] = []
        for q in questions {
            if cold { await chat.clearCache(spec.id, disk: true) }
            messages.append(ChatMessage(role: .user, text: q))
            let start = ContinuousClock.now
            var first: Double?
            var text = ""
            var usage = ChatUsage(promptTokens: 0, completionTokens: 0)
            for try await e in try await chat.stream(model: spec, messages: messages, options: ChatOptions(maxTokens: 24, temperature: 0)) {
                switch e {
                case .delta(let s):
                    if first == nil { let d = ContinuousClock.now - start; first = Double(d.components.attoseconds) / 1e18 + Double(d.components.seconds) }
                    text += s
                case .done(_, let u): usage = u
                default: break
                }
            }
            turns.append(Turn(text: text, usage: usage, firstToken: first ?? 0))
            messages.append(ChatMessage(role: .assistant, text: text))
        }
        return turns
    }

    func testCachedConversationMatchesColdAndReusesHistory() async throws {
        let (chat, spec) = try await service()
        _ = try await chat.complete(model: spec, messages: [ChatMessage(role: .user, text: "hi")], options: ChatOptions(maxTokens: 2))  // load
        await chat.clearCache(spec.id, disk: true)
        let cold = try await conversation(chat, spec, cold: true)
        await chat.clearCache(spec.id, disk: true)
        let warm = try await conversation(chat, spec, cold: false)
        for (i, (c, w)) in zip(cold, warm).enumerated() {
            print("[turn \(i + 1)] cold \(String(format: "%.3f", c.firstToken)) s, warm \(String(format: "%.3f", w.firstToken)) s, "
                  + "prompt \(w.usage.promptTokens), cached \(w.usage.cachedTokens): \(w.text.debugDescription)")
            XCTAssertEqual(c.text, w.text, "turn \(i + 1): the cache changed the output")
            XCTAssertEqual(c.usage.cachedTokens, 0)
            XCTAssertEqual(c.usage.promptTokens, w.usage.promptTokens)
        }
        XCTAssertEqual(warm[0].usage.cachedTokens, 0)
        for i in 1..<warm.count {
            // The previous prompt minus its generation prompt (a dozen tokens) came from the cache.
            XCTAssertGreaterThan(warm[i].usage.cachedTokens, warm[i - 1].usage.promptTokens - 20, "turn \(i + 1)")
            XCTAssertLessThan(warm[i].firstToken, cold[i].firstToken, "turn \(i + 1) should start sooner")
        }
        let stats = await chat.cacheStats()[spec.id]
        print("[stats] \(String(describing: stats))")
        XCTAssertEqual(stats?.hits, 2, "only warm turns 2 and 3 hit")
        XCTAssertEqual(stats?.diskEntries, 1, "turns 2 and 3 grew the conversation by under a third: no new files")
        await chat.clearCache(spec.id, disk: true)
    }

    /// Turn 1 saves its checkpoint to disk; after an unload (memory cache gone) turn 2 still starts warm, unchanged.
    func testCheckpointSurvivesUnloadOnDisk() async throws {
        let (chat, spec) = try await service()
        await chat.clearCache(spec.id, disk: true)
        let cold = try await conversation(chat, spec, cold: true)
        await chat.clearCache(spec.id, disk: true)

        var messages = [ChatMessage(role: .system, text: system), ChatMessage(role: .user, text: questions[0])]
        let first = try await chat.complete(model: spec, messages: messages, options: ChatOptions(maxTokens: 24, temperature: 0))
        _ = await chat.models.unload(spec.id)
        let afterUnload = await chat.cacheStats()[spec.id]
        XCTAssertEqual(afterUnload?.entries, 0, "unloading drops the memory checkpoints")
        XCTAssertEqual(afterUnload?.diskEntries, 1)

        messages += [ChatMessage(role: .assistant, text: first.text), ChatMessage(role: .user, text: questions[1])]
        let diskHitsBefore = afterUnload?.diskHits ?? 0
        let second = try await chat.complete(model: spec, messages: messages, options: ChatOptions(maxTokens: 24, temperature: 0))
        print("[disk] turn 2 prompt \(second.usage.promptTokens), cached \(second.usage.cachedTokens): \(second.text.debugDescription)")
        XCTAssertGreaterThan(second.usage.cachedTokens, first.usage.promptTokens - 20)
        XCTAssertEqual(second.text, cold[1].text)
        let stats = await chat.cacheStats()[spec.id]
        XCTAssertEqual(stats?.diskHits, diskHitsBefore + 1)
        await chat.clearCache(spec.id, disk: true)
    }
}
