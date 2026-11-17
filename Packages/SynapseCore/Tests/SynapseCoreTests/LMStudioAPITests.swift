import XCTest
@testable import SynapseCore

/// LM Studio's /api/v1/chat stream: the events a ChatService timeline turns into, in LM Studio's order and shapes.
final class LMStudioAPITests: XCTestCase {
    private func names(_ events: [LMStudioRun.Event]) -> [String] { events.map(\.0) }

    private func encode(_ v: any Encodable) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as? [String: Any])
    }

    func testTimelineBecomesLMStudioEvents() throws {
        var run = LMStudioRun(model: "qwen3.5-0.8b", thinking: true, responseID: "resp_1")
        var out: [LMStudioRun.Event] = []
        for e: ChatEvent in [.progress(.loadStarted), .progress(.loaded(seconds: 1.5)), .progress(.promptStarted),
                             .progress(.prompt(fraction: 0.5)), .progress(.promptDone),
                             .delta("<think>Need"), .delta(" to</th"), .delta("ink>Par"), .delta("is."),
                             .done(finishReason: "stop", usage: ChatUsage(promptTokens: 20, completionTokens: 4))] {
            out += run.consume(e)
        }
        out += run.close()
        XCTAssertEqual(names(out), ["model_load.start", "model_load.end", "prompt_processing.start", "prompt_processing.progress",
                                    "prompt_processing.end", "reasoning.start", "reasoning.delta", "reasoning.delta",
                                    "reasoning.end", "message.start", "message.delta", "message.delta", "message.end"])
        XCTAssertEqual(try encode(AnyEncodableDict(out[1].1))["load_time_seconds"] as? Double, 1.5)
        XCTAssertEqual(try encode(AnyEncodableDict(out[3].1))["progress"] as? Double, 0.5)

        let result = try encode(run.result())
        XCTAssertEqual(result["model_instance_id"] as? String, "qwen3.5-0.8b")
        XCTAssertEqual(result["response_id"] as? String, "resp_1")
        let output = try XCTUnwrap(result["output"] as? [[String: Any]])
        XCTAssertEqual(output.map { $0["type"] as? String }, ["reasoning", "message"])
        XCTAssertEqual(output[0]["content"] as? String, "Need to")
        XCTAssertEqual(output[1]["content"] as? String, "Paris.")
        let stats = try XCTUnwrap(result["stats"] as? [String: Any])
        XCTAssertEqual(stats["input_tokens"] as? Int, 20)
        XCTAssertEqual(stats["total_output_tokens"] as? Int, 4)
        XCTAssertEqual(stats["model_load_time_seconds"] as? Double, 1.5)
        XCTAssertNotNil(stats["time_to_first_token_seconds"] as? Double)
    }

    func testResidentModelHasNoLoadEventsOrLoadTime() throws {
        var run = LMStudioRun(model: "m", thinking: false, responseID: nil)
        var out: [LMStudioRun.Event] = []
        for e: ChatEvent in [.progress(.promptStarted), .progress(.promptDone), .delta("Hi"),
                             .done(finishReason: "stop", usage: ChatUsage(promptTokens: 3, completionTokens: 1))] {
            out += run.consume(e)
        }
        out += run.close()
        XCTAssertEqual(names(out), ["prompt_processing.start", "prompt_processing.end", "message.start", "message.delta", "message.end"])
        let result = try encode(run.result())
        XCTAssertNil(result["response_id"])
        XCTAssertNil((result["stats"] as? [String: Any])?["model_load_time_seconds"])
    }

    func testInputShapes() throws {
        XCTAssertEqual(try LMStudioParse.input(.string("Hi")), [.text("Hi")])
        let parts = JSONValue.array([.object(["type": .string("text"), "content": .string("Describe")]),
                                     .object(["type": .string("image"), "data_url": .string("data:image/png;base64,AA==")])])
        XCTAssertEqual(try LMStudioParse.input(parts), [.text("Describe"), .image("data:image/png;base64,AA==")])
        XCTAssertThrowsError(try LMStudioParse.input(.array([.object(["type": .string("file")])])))
        XCTAssertThrowsError(try LMStudioParse.input(.array([])))
    }
}
