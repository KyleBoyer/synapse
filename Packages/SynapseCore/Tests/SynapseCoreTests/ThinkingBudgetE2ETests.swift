import XCTest
@testable import SynapseCore

/// The thinking budget on real Qwen3.5 (2B by default; SYNAPSE_BUDGET_MODEL picks another): the reasoning span is closed when the budget runs out and an answer follows.
final class ThinkingBudgetE2ETests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
    }

    func testBudgetCutsThinkingAndTheModelStillAnswers() async throws {
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let chat = ChatService(store: ModelStore(root: root))
        let spec = try await chat.resolve(ProcessInfo.processInfo.environment["SYNAPSE_BUDGET_MODEL"] ?? "qwen3.5-2b")
        let messages = [ChatMessage(role: .user, text: "A train leaves at 9:40 and arrives at 13:05. How long is the trip? Give hours and minutes.")]
        func ask(_ budget: Int?) async throws -> (thinking: String, answer: String, tokens: Int) {
            var o = ChatOptions(maxTokens: 1200, temperature: 0, enableThinking: true)
            o.thinkingBudget = budget
            let r = try await chat.complete(model: spec, messages: messages, options: o)
            let parts = r.text.components(separatedBy: "</think>")
            let thinkingTokens = try await chat.countTokens(model: spec, messages: [ChatMessage(role: .user, text: parts[0])], options: ChatOptions())
            return (parts[0], parts.count > 1 ? parts[1...].joined() : "", thinkingTokens)
        }
        let free = try await ask(nil)
        let capped = try await ask(64)
        print("[budget] free: \(free.tokens) thinking tokens, answer \(free.answer.suffix(80).debugDescription)")
        print("[budget] 64:   \(capped.tokens) thinking tokens, answer \(capped.answer.suffix(80).debugDescription)")
        XCTAssertGreaterThan(free.tokens, 150, "the prompt should need more than the budget")
        XCTAssertLessThan(capped.tokens, 64 + 30, "thinking (plus a little chat-template overhead) stops near the budget")
        XCTAssertFalse(capped.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "an answer follows the forced </think>")
    }
}
