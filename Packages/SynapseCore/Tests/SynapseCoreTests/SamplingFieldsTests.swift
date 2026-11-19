import Hummingbird
import XCTest
@testable import SynapseCore

/// Sampling fields beyond temperature/top_p: parsed from any route's body, validated, and passed to every engine.
final class SamplingFieldsTests: XCTestCase {
    private func read(_ json: String) throws -> SamplingFields { try SamplingFields.read(Data(json.utf8)) }

    func testFieldsReachChatOptionsAndMLXParameters() throws {
        var o = ChatOptions()
        try read(#"{"seed":7,"top_k":40,"min_p":0.05,"presence_penalty":0.5,"frequency_penalty":-0.5,"repetition_penalty":1.1}"#).apply(to: &o)
        XCTAssertEqual(o.seed, 7); XCTAssertEqual(o.topK, 40); XCTAssertEqual(o.minP, 0.05)
        XCTAssertEqual(o.presencePenalty, 0.5); XCTAssertEqual(o.frequencyPenalty, -0.5); XCTAssertEqual(o.repetitionPenalty, 1.1)
        let p = ChatService.parameters(o, .full)
        XCTAssertEqual(p.seed, 7); XCTAssertEqual(p.topK, 40); XCTAssertEqual(p.minP, 0.05)
        XCTAssertEqual(p.presencePenalty, 0.5); XCTAssertEqual(p.frequencyPenalty, -0.5); XCTAssertEqual(p.repetitionPenalty, 1.1)
    }

    func testLMStudioSpellingAndAbsentFieldsKeepDefaults() throws {
        var o = ChatOptions()
        try read(#"{"repeat_penalty":1.2}"#).apply(to: &o)
        XCTAssertEqual(o.repetitionPenalty, 1.2)
        XCTAssertNil(o.seed); XCTAssertNil(o.topK)
        let defaults = ChatService.parameters(ChatOptions(), .full)
        XCTAssertNil(defaults.seed); XCTAssertNil(defaults.presencePenalty)
    }

    func testOutOfRangeValuesAre400s() {
        for body in [#"{"presence_penalty":2.5}"#, #"{"frequency_penalty":-3}"#, #"{"repetition_penalty":0}"#,
                     #"{"top_k":-1}"#, #"{"min_p":1.5}"#] {
            XCTAssertThrowsError(try read(body), body) { e in
                XCTAssertEqual((e as? HTTPError)?.status, .badRequest, body)
            }
        }
    }

    func testServerBodyCarriesThemUnderBothPenaltyNames() throws {
        var o = ChatOptions(); o.topK = 20; o.minP = 0.1; o.seed = 3; o.repetitionPenalty = 1.05
        let body = try MLXVLMChat.body([ChatMessage(role: .user, text: "hi")], options: o, model: "/m")
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(j["top_k"] as? Int, 20); XCTAssertEqual(j["seed"] as? Int, 3)
        XCTAssertEqual((j["min_p"] as? Double).map { Float($0) }, 0.1)
        XCTAssertNotNil(j["repetition_penalty"]); XCTAssertNotNil(j["repeat_penalty"])
        XCTAssertNil(j["presence_penalty"])
    }
}
