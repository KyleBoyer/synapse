import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// Anthropic Messages parsing and stream assembly, without loading a model (the real model runs in
/// scripts/verify-anthropic-api.py through the official SDK).
final class AnthropicAPITests: XCTestCase {
    private func request(_ s: String) throws -> MessagesRequest { try JSONDecoder().decode(MessagesRequest.self, from: Data(s.utf8)) }

    func testSystemImagesAndToolTurnsBecomeChatParts() throws {
        let body = try request(#"""
        {"model":"claude-x","max_tokens":10,"system":[{"type":"text","text":"be brief"}],
         "messages":[
          {"role":"user","content":[{"type":"text","text":"look"},
            {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]},
          {"role":"assistant","content":[{"type":"thinking","thinking":"hm","signature":""},
            {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Paris","days":2}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"sunny"}]}]}
        """#)
        let parsed = try AnthropicParse.messages(body)
        XCTAssertEqual(parsed.map(\.0), [.system, .user, .assistant, .user])
        XCTAssertEqual(parsed[0].1, [.text("be brief")])
        XCTAssertEqual(parsed[1].1, [.text("look"), .image("data:image/png;base64,AAAA")])
        XCTAssertEqual(parsed[2].1, [.text("<tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n<parameter=days>\n2\n</parameter>\n</function>\n</tool_call>")])
        XCTAssertEqual(parsed[3].1, [.text("<tool_response>\nsunny\n</tool_response>")])
    }

    func testRejectsUnknownBlocksRolesAndServerTools() throws {
        XCTAssertThrowsError(try AnthropicParse.messages(try request(#"{"messages":[{"role":"user","content":[{"type":"document"}]}]}"#)))
        XCTAssertThrowsError(try AnthropicParse.messages(try request(#"{"messages":[{"role":"system","content":"x"}]}"#)))
        XCTAssertThrowsError(try AnthropicParse.tools(try request(#"{"messages":[],"tools":[{"type":"web_search_20250305","name":"web_search"}]}"#)))
        let none = try request(#"{"messages":[],"tools":[{"name":"f","input_schema":{"type":"object"}}],"tool_choice":{"type":"none"}}"#)
        XCTAssertEqual(try AnthropicParse.tools(none), [])
    }

    func testThinkSplitterAcrossChunkBoundaries() {
        var s = ThinkSplitter()
        var thinking = "", text = ""
        for chunk in ["Let me", " think.</th", "ink>\n\nPar", "is."] {
            let r = s.feed(chunk); thinking += r.thinking; text += r.text
        }
        let tail = s.finish(); thinking += tail.thinking; text += tail.text
        XCTAssertEqual(thinking, "Let me think.")
        XCTAssertEqual(text, "\n\nParis.")
    }

    func testStopScannerCutsAtEarliestStopSplitAcrossChunks() {
        var s = StopScanner(["END", "\n\nHuman:"])
        var out = ""
        var hit: String?
        for chunk in ["one two E", "N", "D three"] {
            let r = s.feed(chunk); out += r.text
            if let h = r.hit { hit = h; break }
        }
        XCTAssertEqual(out, "one two ")
        XCTAssertEqual(hit, "END")
        var plain = StopScanner([])
        XCTAssertEqual(plain.feed("abc").text, "abc")
    }

    func testAssemblerEmitsBlocksInOrder() throws {
        var a = MessageAssembler()
        a.add("thinking", "\nhmm")
        a.add("text", "\n\nHi")
        a.add("text", " there")
        a.toolUse(name: "f", arguments: #"{"x":1}"#)
        a.close()
        XCTAssertEqual(a.blocks.map(\.type), ["thinking", "text", "tool_use"])
        XCTAssertEqual(a.blocks[0].thinking, "hmm")
        XCTAssertEqual(a.blocks[1].text, "Hi there")
        XCTAssertEqual(a.blocks[2].input, .object(["x": .number(1)]))
        let types = a.drain().compactMap { $0.values["type"] as? String }
        XCTAssertEqual(types, ["content_block_start", "content_block_delta", "content_block_delta", "content_block_stop",
                               "content_block_start", "content_block_delta", "content_block_delta", "content_block_stop",
                               "content_block_start", "content_block_delta", "content_block_stop"])
    }

    func testRoutesReturnAnthropicErrorShape() async throws {
        let store = try TestSupport.store(downloaded: [])
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/nonexistent")),
                             settings: box, engineFactory: { _, _ in FakeEngine() })
        let app = Application(router: buildRouter(queue: queue, store: store, settings: box))
        try await app.test(.router) { c in
            for uri in ["/v1/messages", "/v1/messages/count_tokens"] {
                try await c.execute(uri: uri, method: .post, headers: [.contentType: "application/json"],
                                    body: ByteBuffer(string: #"{"model":"claude-sonnet-4-5","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}"#)) {
                    XCTAssertEqual($0.status, .serviceUnavailable)
                    let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as? [String: Any])
                    XCTAssertEqual(o["type"] as? String, "error")
                    XCTAssertEqual((o["error"] as? [String: Any])?["type"] as? String, "api_error")
                    XCTAssertNotNil((o["error"] as? [String: Any])?["message"] as? String)
                }
            }
        }
    }
}
