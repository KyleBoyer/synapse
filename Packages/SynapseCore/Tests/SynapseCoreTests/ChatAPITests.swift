import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// Chat endpoint tests that never load a model.
final class ChatAPITests: XCTestCase {
    // MARK: ChatParse.parts

    private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    private func assertBadRequest(_ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? HTTPError)?.status, .badRequest, file: file, line: line)
        }
    }

    func testPartsString() throws {
        XCTAssertEqual(try ChatParse.parts(try json(#""hi""#)), [.text("hi")])
        XCTAssertEqual(try ChatParse.parts(nil), [])
    }

    func testPartsChatCompletionsArray() throws {
        let v = try json(#"""
        [{"type":"text","text":"look"},
         {"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},
         {"type":"image_url","image_url":"https://x/y.png"}]
        """#)
        XCTAssertEqual(try ChatParse.parts(v), [.text("look"), .image("data:image/png;base64,AAAA"), .image("https://x/y.png")])
    }

    func testPartsResponsesTypes() throws {
        let v = try json(#"[{"type":"input_text","text":"a"},{"type":"input_image","image_url":"https://x/z.jpg"}]"#)
        XCTAssertEqual(try ChatParse.parts(v), [.text("a"), .image("https://x/z.jpg")])
    }

    func testPartsRejectsUnsupportedAndMalformed() throws {
        assertBadRequest { try ChatParse.parts(try self.json(#"[{"type":"input_audio"}]"#)) }
        assertBadRequest { try ChatParse.parts(try self.json(#"[{"text":"no type"}]"#)) }
        assertBadRequest { try ChatParse.parts(try self.json(#"[{"type":"image_url"}]"#)) }
        assertBadRequest { try ChatParse.parts(try self.json("5")) }
    }

    // MARK: ChatParse.responseMessages

    func testResponseMessagesString() throws {
        let m = try ChatParse.responseMessages(try json(#""hello""#), instructions: nil)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].0, .user)
        XCTAssertEqual(m[0].1, [.text("hello")])
    }

    func testResponseMessagesInstructionsAndItems() throws {
        let input = try json(#"""
        [{"role":"developer","content":"be nice"},
         {"role":"user","content":[{"type":"input_text","text":"q"},{"type":"input_image","image_url":"https://x/a.png"}]},
         {"role":"assistant","content":[{"type":"output_text","text":"a"}]}]
        """#)
        let m = try ChatParse.responseMessages(input, instructions: "sys")
        XCTAssertEqual(m.map(\.0), [.system, .system, .user, .assistant])
        XCTAssertEqual(m[0].1, [.text("sys")])
        XCTAssertEqual(m[1].1, [.text("be nice")])
        XCTAssertEqual(m[2].1, [.text("q"), .image("https://x/a.png")])
        XCTAssertEqual(m[3].1, [.text("a")])
    }

    func testResponseMessagesRejectsBadInput() throws {
        assertBadRequest { try ChatParse.responseMessages(try self.json("5"), instructions: nil) }
        assertBadRequest { try ChatParse.responseMessages(try self.json(#"[{"role":"tool","content":"x"}]"#), instructions: nil) }
        assertBadRequest { try ChatParse.responseMessages(try self.json(#"[{"foo":1}]"#), instructions: nil) }
    }

    // MARK: ImageFetcher

    func testImageFetcherDataURLRoundTrip() async throws {
        let bytes = try Data(contentsOf: TestSupport.fixture("penguin.png"))
        let loaded = try await ImageFetcher.load("data:image/png;base64," + bytes.base64EncodedString())
        XCTAssertEqual(loaded, bytes)
    }

    func testImageFetcherRejectsNonBase64DataURL() async throws {
        await assertLoadFails("data:image/png,rawbytes")
    }

    func testImageFetcherRejectsLocalFiles() async throws {
        await assertLoadFails("file:///etc/passwd")
        await assertLoadFails("/etc/passwd")
    }

    private func assertLoadFails(_ url: String, line: UInt = #line) async {
        do { _ = try await ImageFetcher.load(url); XCTFail("expected failure for \(url)", line: line) }
        catch { XCTAssertEqual((error as? HTTPError)?.status, .badRequest, line: line) }
    }

    // MARK: ModelResolver

    func testResolveChatPicksSmallestDownloaded() throws {
        let s = try ModelResolver.resolveChat(requested: nil, downloaded: ["qwen3.5-2b", "qwen3.5-9b", "whisper-tiny"])
        XCTAssertEqual(s.id, "qwen3.5-2b")
        XCTAssertEqual(try ModelResolver.resolveChat(requested: "", downloaded: ["qwen3.5-9b"]).id, "qwen3.5-9b")
        XCTAssertEqual(try ModelResolver.resolveChat(requested: "qwen3.5-9b", downloaded: ["qwen3.5-2b", "qwen3.5-9b"]).id, "qwen3.5-9b")
    }

    func testResolveChatErrors() {
        func err(_ r: String?, _ d: Set<String>) -> ResolveError? {
            do { _ = try ModelResolver.resolveChat(requested: r, downloaded: d); return nil } catch { return error as? ResolveError }
        }
        XCTAssertEqual(err("whisper-tiny", ["whisper-tiny"]), .wrongKind("whisper-tiny"))
        XCTAssertEqual(err(nil, ["whisper-tiny"]), .noChatModel)
        XCTAssertEqual(err(nil, []), .noChatModel)
        XCTAssertEqual(err("nope", []), .unknownModel("nope"))
        XCTAssertEqual(err("qwen3.5-0.8b", []), .notDownloaded("qwen3.5-0.8b"))
    }

    func testTranscriptionResolveRejectsChatModel() {
        XCTAssertThrowsError(try ModelResolver.resolve(requested: "qwen3.5-0.8b", task: .transcribe, language: nil,
                                                       defaultID: "parakeet-v3", downloaded: ["qwen3.5-0.8b"])) {
            XCTAssertEqual($0 as? ResolveError, .wrongKind("qwen3.5-0.8b"))
        }
    }

    // MARK: ThinkFilter

    private func run(_ f: inout ThinkFilter, _ chunks: [String]) -> String {
        chunks.map { f.feed($0) }.joined() + f.finish()
    }

    func testThinkFilterStripsStreamedBlock() {
        var f = ThinkFilter(enabled: true)
        XCTAssertEqual(run(&f, ["<th", "ink>reasoning</th", "ink>\n\nHello", " world"]), "Hello world")
    }

    func testThinkFilterPassesPlainTextChunkedMidWord() {
        var f = ThinkFilter(enabled: true)
        XCTAssertEqual(run(&f, ["Hel", "lo wor", "ld"]), "Hello world")
        var g = ThinkFilter(enabled: true)
        XCTAssertEqual(run(&g, ["<b", ">bold</b>"]), "<b>bold</b>")
    }

    func testThinkFilterDisabledPassesEverything() {
        var f = ThinkFilter(enabled: false)
        XCTAssertEqual(run(&f, ["<think>x</think>", "\n\nHi"]), "<think>x</think>\n\nHi")
    }

    // MARK: Routes

    private func makeApp(downloaded: [String]) throws -> Application<RouterResponder<SynapseContext>> {
        let store = try TestSupport.store(downloaded: downloaded)
        let box = SettingsBox(Settings())
        // The chat routes never touch the queue; the ffmpeg path is never executed.
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/nonexistent")),
                             settings: box, engineFactory: { _, _ in FakeEngine() })
        return Application(router: buildRouter(queue: queue, store: store, settings: box))
    }

    private func post(_ app: Application<RouterResponder<SynapseContext>>, _ uri: String, _ body: String) async throws
        -> (status: HTTPResponse.Status, body: String)
    {
        try await app.test(.router) { c in
            try await c.execute(uri: uri, method: .post, headers: [.contentType: "application/json"],
                                body: ByteBuffer(string: body)) { ($0.status, String(buffer: $0.body)) }
        }
    }

    private func assertOpenAIError(_ body: String, line: UInt = #line) {
        let o = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let msg = (o?["error"] as? [String: Any])?["message"] as? String
        XCTAssertFalse(msg?.isEmpty ?? true, "no error.message in \(body)", line: line)
    }

    func testChatCompletionsWithoutChatModelIs503() async throws {
        let app = try makeApp(downloaded: ["whisper-tiny"])
        let r = try await post(app, "/v1/chat/completions", #"{"messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(r.status, .serviceUnavailable)
        assertOpenAIError(r.body)
    }

    func testChatCompletionsMalformedJSONIs400() async throws {
        let app = try makeApp(downloaded: [])
        var r = try await post(app, "/v1/chat/completions", "{not json")
        XCTAssertEqual(r.status, .badRequest)
        assertOpenAIError(r.body)
        // Valid JSON but missing required `messages` is also a decode failure.
        r = try await post(app, "/v1/chat/completions", "{}")
        XCTAssertEqual(r.status, .badRequest)
    }

    func testChatCompletionsWithWhisperModelIs400() async throws {
        let app = try makeApp(downloaded: ["whisper-tiny"])
        let r = try await post(app, "/v1/chat/completions", #"{"model":"whisper-tiny","messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(r.status, .badRequest)
        assertOpenAIError(r.body)
    }

    func testResponsesResolvesModelBeforeParsingInput() async throws {
        // The route resolves the model first, so `input: 5` with no chat model is 503, not 400.
        let none = try makeApp(downloaded: [])
        var r = try await post(none, "/v1/responses", #"{"input":5}"#)
        XCTAssertEqual(r.status, .serviceUnavailable)
        assertOpenAIError(r.body)
        // Explicit wrong-kind model still fails 400 before input parsing.
        r = try await post(none, "/v1/responses", #"{"model":"whisper-tiny","input":5}"#)
        XCTAssertEqual(r.status, .badRequest)
    }

    func testBadPayloadsWithChatModelDownloadedAre400() async throws {
        // Model resolves, so parsing/fetching fails before any model load.
        let app = try makeApp(downloaded: ["qwen3.5-0.8b"])
        var r = try await post(app, "/v1/responses", #"{"input":5}"#)
        XCTAssertEqual(r.status, .badRequest)
        assertOpenAIError(r.body)
        r = try await post(app, "/v1/chat/completions", #"{"messages":[{"role":"user","content":[{"type":"input_audio"}]}]}"#)
        XCTAssertEqual(r.status, .badRequest)
        r = try await post(app, "/v1/chat/completions",
                           #"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"file:///etc/passwd"}}]}]}"#)
        XCTAssertEqual(r.status, .badRequest)
    }

    func testModelsListsDownloadedChatModels() async throws {
        let app = try makeApp(downloaded: ["qwen3.5-0.8b", "whisper-tiny"])
        try await app.test(.router) { c in
            try await c.execute(uri: "/v1/models", method: .get) {
                let body = String(buffer: $0.body)
                XCTAssertTrue(body.contains("qwen3.5-0.8b"))
                XCTAssertTrue(body.contains("whisper-tiny"))
                XCTAssertFalse(body.contains("qwen3.5-9b"))
            }
        }
    }

    // MARK: Function tools

    func testToolHistoryBecomesMarkupTheModelWrites() throws {
        let raw = try JSONDecoder().decode([JSONValue].self, from: Data(#"""
        [{"role":"user","content":"Weather in Paris?"},
         {"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},
         {"role":"tool","tool_call_id":"call_1","content":"18 C, light rain"}]
        """#.utf8))
        let parsed = try ChatParse.chatMessages(raw)
        XCTAssertEqual(parsed.map(\.0), [.user, .assistant, .user])
        XCTAssertEqual(parsed[1].1, [.text("<tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>")])
        XCTAssertEqual(parsed[2].1, [.text("<tool_response>\n18 C, light rain\n</tool_response>")])

        let input = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"role":"user","content":"Weather in Paris?"},
         {"type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Paris\"}"},
         {"type":"function_call_output","call_id":"call_1","output":"18 C"}]
        """#.utf8))
        let items = try ChatParse.responseMessages(input, instructions: nil)
        XCTAssertEqual(items.map(\.0), [.user, .assistant, .user])
        XCTAssertEqual(items[2].1, [.text("<tool_response>\n18 C\n</tool_response>")])
    }

    func testFunctionToolsInBothShapes() throws {
        let tools = try JSONDecoder().decode([JSONValue].self, from: Data(#"""
        [{"type":"function","function":{"name":"a","description":"A.","parameters":{"type":"object"}}},
         {"type":"function","name":"b","parameters":{"type":"object","properties":{}}}]
        """#.utf8))
        XCTAssertEqual(try ChatParse.functionTools(tools, choice: nil).map(\.name), ["a", "b"])
        XCTAssertEqual(try ChatParse.functionTools(tools, choice: .string("none")), [])
        let web = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"type":"web_search"}]"#.utf8))
        XCTAssertThrowsError(try ChatParse.functionTools(web, choice: nil))
    }
}
