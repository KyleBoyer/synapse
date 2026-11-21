import XCTest
@testable import SynapseCore

/// Cached prompt tokens reach every API's usage fields, in each API's own shape.
final class CachedUsageTests: XCTestCase {
    private let usage = ChatUsage(promptTokens: 120, completionTokens: 5, cachedTokens: 100)

    private func json(_ v: any Encodable) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as? [String: Any])
    }

    func testChatCompletionsReportsPromptTokensDetails() throws {
        let o = try json(ChatUsageWire(usage))
        XCTAssertEqual(o["prompt_tokens"] as? Int, 120)
        XCTAssertEqual((o["prompt_tokens_details"] as? [String: Int])?["cached_tokens"], 100)
    }

    func testResponsesReportsInputTokensDetails() throws {
        let o = try json(ResponseWire.Usage(usage))
        XCTAssertEqual(o["input_tokens"] as? Int, 120)
        XCTAssertEqual((o["input_tokens_details"] as? [String: Int])?["cached_tokens"], 100)
    }

    func testLMStudioStatsCountCachedTokens() throws {
        var run = LMStudioRun(model: "m", responseID: nil)
        for e: ChatEvent in [.delta("Hi"), .done(finishReason: "stop", usage: usage)] { _ = run.consume(e) }
        _ = run.close()
        let stats = try XCTUnwrap(try json(run.result())["stats"] as? [String: Any])
        XCTAssertEqual(stats["cached_tokens"] as? Int, 100)
    }
}
