import Foundation
import Hummingbird
import Synchronization
import XCTest
@testable import SynapseCore

final class ServerToolsTests: XCTestCase {
    private static func turn(_ events: [ChatEvent]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }

    private func collect(_ s: AsyncThrowingStream<ToolLoopEvent, Error>) async throws -> [ToolLoopEvent] {
        var out: [ToolLoopEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    func testSplitKeepsClientToolsAndRecognizesEveryServerType() throws {
        let tools: [JSONValue] = [.object(["type": .string("web_search_20250305"), "max_uses": .number(2)]),
                                  .object(["type": .string("image_generation")]), .object(["type": .string("synapse")]),
                                  .object(["type": .string("function"), "name": .string("lookup")])]
        var manual = ToolSettings()
        manual.alwaysOn = []
        let (server, rest) = try ServerTools.split(tools, settings: manual)
        XCTAssertTrue(server.webSearch)
        XCTAssertEqual(server.maxSearches, 2)
        XCTAssertNotNil(server.image)
        XCTAssertTrue(server.synapse)
        XCTAssertEqual(rest, [tools[3]])
        XCTAssertEqual(server.functions.map(\.name), ["web_search", "web_fetch", "generate_image", "synapse_time", "date_difference",
                                                    "calculate", "synapse_models", "synapse_status"])
        var none = ToolSettings()
        none.alwaysOn = []
        let fetchOnly = try ServerTools.split([.object(["type": .string("web_fetch_20250910")])], settings: none).0
        XCTAssertEqual(fetchOnly.functions.map(\.name), ["web_fetch"])
        XCTAssertNil(ServerTools().kind(of: "web_search"), "a tool the request did not turn on is the client's")
    }

    func testSettingsFillDefaultsAddAlwaysOnToolsAndTurnSearchOff() throws {
        var settings = ToolSettings()
        settings.imageModel = "flux2-klein-4b"
        settings.imageSize = "512x512"
        settings.alwaysOn = [.webSearch, .synapse]
        let (server, _) = try ServerTools.split([.object(["type": .string("image_generation"), "size": .string("768x768")])], settings: settings)
        XCTAssertEqual(server.image?.model, "flux2-klein-4b")
        XCTAssertEqual(server.image?.size, "768x768", "the request's own size wins")
        XCTAssertTrue(server.webSearch && server.synapse)
        XCTAssertNil(try ServerTools.split(nil, settings: settings).0.image, "image generation only when the settings or the request ask")

        settings.searchProvider = .off
        XCTAssertFalse(try ServerTools.split(nil, settings: settings).0.webSearch, "always-on search stays off with no provider")
        XCTAssertThrowsError(try ServerTools.split([.object(["type": .string("web_search")])], settings: settings))
    }

    func testSearchAPIResultsParse() {
        let brave = Data(#"{"web":{"results":[{"title":"A <strong>b</strong>","url":"https://a.com","description":"x &amp; y"}]}}"#.utf8)
        XCTAssertEqual(WebSearch.results(brave, list: ["web", "results"], snippet: "description", count: 5),
                       [WebResult(title: "A b", url: "https://a.com", snippet: "x & y")])
        let tavily = Data(#"{"results":[{"title":"T","url":"https://t.com","content":"c"},{"title":"U","url":"https://u.com","content":"d"}]}"#.utf8)
        XCTAssertEqual(WebSearch.results(tavily, list: ["results"], snippet: "content", count: 1).map(\.url), ["https://t.com"])
    }

    /// The model searches, reads the results, then answers; the client sees the call and one done with summed usage.
    func testLoopRunsBuiltinCallsAndFeedsResultsBack() async throws {
        let seen = Mutex<[([ChatMessage], [String])]>([])
        let runner = ServerToolRunner(tools: ServerTools(webSearch: true), maxRounds: 3)
        let events = try await collect(runner.stream(
            messages: [ChatMessage(role: .user, text: "Who won?")], options: ChatOptions(tools: [ChatTool(name: "mine", description: "", parametersJSON: "{}")]),
            generate: { messages, options in
                let round = seen.withLock { $0.append((messages, options.tools.map(\.name))); return $0.count }
                return Self.turn(round == 1
                    ? [.delta("Let me check."), .toolCall(name: "web_search", arguments: #"{"query":"final score"}"#),
                       .done(finishReason: "stop", usage: ChatUsage(promptTokens: 10, completionTokens: 5))]
                    : [.delta("Team A won."), .done(finishReason: "stop", usage: ChatUsage(promptTokens: 30, completionTokens: 4, cachedTokens: 9))])
            },
            execute: { call, _ in
                var c = call
                c.output = .search(query: call.query, results: [WebResult(title: "Final", url: "https://example.com", snippet: "A beat B")])
                return c
            }))

        let rounds = seen.withLock { $0 }
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds[0].1, ["web_search", "mine"])
        let fed = rounds[1].0.map(\.text).joined(separator: "\n")
        XCTAssertTrue(fed.contains("<tool_response>") && fed.contains("https://example.com") && fed.contains("A beat B"), fed)

        var started = 0, finished = 0, text = ""
        var done: ChatUsage?
        for e in events {
            switch e {
            case .toolStarted(let c): started += 1; XCTAssertEqual(c.query, "final score"); XCTAssertTrue(c.id.hasPrefix("ws_"))
            case .toolFinished: finished += 1
            case .chat(.delta(let s)): text += s
            case .chat(.done(_, let u)): XCTAssertNil(done, "one done for the whole loop"); done = u
            case .chat: break
            }
        }
        XCTAssertEqual([started, finished], [1, 1])
        XCTAssertEqual(text, "Let me check.Team A won.")
        XCTAssertEqual(done, ChatUsage(promptTokens: 40, completionTokens: 9, cachedTokens: 9))
    }

    func testClientCallEndsTheLoopAndTheLastRoundHasNoBuiltins() async throws {
        let runner = ServerToolRunner(tools: ServerTools(synapse: true), maxRounds: 2)
        let tools = Mutex<[[String]]>([])
        let events = try await collect(runner.stream(
            messages: [ChatMessage(role: .user, text: "x")], options: ChatOptions(),
            generate: { _, o in
                tools.withLock { $0.append(o.tools.map(\.name)) }
                return Self.turn([.toolCall(name: "synapse_time", arguments: "{}"), .done(finishReason: "stop", usage: ChatUsage(promptTokens: 1, completionTokens: 1))])
            },
            execute: { call, _ in var c = call; c.output = .info("{}"); return c }))
        XCTAssertEqual(tools.withLock { $0 }, [ServerToolKind.synapseSet.map(\.rawValue), []])
        XCTAssertEqual(events.filter { if case .toolFinished = $0 { true } else { false } }.count, 1)

        let client = try await collect(ServerToolRunner(tools: ServerTools(synapse: true)).stream(
            messages: [], options: ChatOptions(),
            generate: { _, _ in Self.turn([.toolCall(name: "lookup", arguments: "{}"), .done(finishReason: "stop", usage: ChatUsage(promptTokens: 1, completionTokens: 1))]) },
            execute: { call, _ in XCTFail("no built-in was called"); return call }))
        guard case .chat(.toolCall(let name, _)) = client.first else { return XCTFail("\(client)") }
        XCTAssertEqual(name, "lookup")
    }

    func testSearchLimitIsReportedToTheModel() async throws {
        let runner = ServerToolRunner(tools: ServerTools(webSearch: true, maxSearches: 0), maxRounds: 2)
        let events = try await collect(runner.stream(
            messages: [], options: ChatOptions(),
            generate: { _, _ in Self.turn([.toolCall(name: "web_search", arguments: #"{"query":"q"}"#), .done(finishReason: "stop", usage: ChatUsage(promptTokens: 1, completionTokens: 1))]) },
            execute: { call, _ in XCTFail("over the limit"); return call }))
        guard case .toolFinished(let call)? = events.first(where: { if case .toolFinished = $0 { true } else { false } }) else { return XCTFail() }
        XCTAssertNotNil(call.error)
    }

    func testDuckDuckGoResultsParseAndSkipAds() {
        let html = """
            <div class="result result--ad"><a class="result__a" href="https://duckduckgo.com/y.js?ad=1">Ad</a>
            <a class="result__snippet" href="x">Buy</a></div>
            <div class="result"><h2><a rel="nofollow" class="result__a" href="https://www.swift.org/">Swift &amp; <b>You</b></a></h2>
            <a class="result__snippet" href="https://www.swift.org/"><b>Swift</b> is a &quot;language&quot;.</a></div>
            <div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&rut=1">Old</a>
            <a class="result__snippet" href="y">Wrapped</a></div>
            """
        let results = WebSearch.parse(html)
        XCTAssertEqual(results.map(\.url), ["https://www.swift.org/", "https://example.com/a"])
        XCTAssertEqual(results.first?.title, "Swift & You")
        XCTAssertEqual(results.map(\.snippet), [#"Swift is a "language"."#, "Wrapped"])
    }

    func testResponsesItemsFollowTheOrderEventsHappen() {
        var asm = ResponsesAssembler()
        asm.reasoning("hmm")
        var call = ServerToolCall(id: "ws_1", kind: .webSearch, arguments: #"{"query":"q"}"#)
        asm.toolStarted(call)
        call.output = .search(query: "q", results: [WebResult(title: "t", url: "https://e.com", snippet: "s")])
        asm.toolFinished(call)
        asm.text("\nAnswer")
        asm.functionCall(name: "mine", arguments: "{}")
        asm.finish(messageStatus: "completed", alwaysMessage: true)
        let events = asm.drain().map(\.type)
        XCTAssertEqual(asm.items.map(\.id).count, 4)
        guard case .reasoning = asm.items[0], case .webSearch(let ws) = asm.items[1], case .message(let m) = asm.items[2],
              case .functionCall = asm.items[3] else { return XCTFail("\(asm.items)") }
        XCTAssertEqual(ws.status, "completed")
        XCTAssertEqual(ws.action.sources?.first?.url, "https://e.com")
        XCTAssertEqual(m.content.first?.text, "Answer")
        XCTAssertEqual(asm.text, "Answer")
        for t in ["response.web_search_call.in_progress", "response.web_search_call.searching", "response.web_search_call.completed",
                  "response.reasoning_text.done", "response.output_text.done", "response.function_call_arguments.done"] {
            XCTAssertTrue(events.contains(t), t)
        }
        XCTAssertEqual(events.filter { $0 == "response.output_item.added" }.count, 4)
        XCTAssertEqual(events.filter { $0 == "response.output_item.done" }.count, 4)
    }

    /// Qwen3.5 2B's real slip: the strict parser rejects it, and the call used to vanish from the reply.
    func testMalformedToolMarkupIsRecovered() throws {
        let slip = "<tool_call>\n<function=web_search>\n<parameter=query\nlatest stable Swift version\n</parameter>\n</function>\n</tool_call>"
        let call = try XCTUnwrap(ToolMarkup.recover(slip))
        XCTAssertEqual(call.name, "web_search")
        XCTAssertEqual(call.argumentsJSON, #"{"query":"latest stable Swift version"}"#)
        let two = try XCTUnwrap(ToolMarkup.recover("<function=f>\n<parameter=n>\n3\n<parameter=s>\nhi there\n</function>"))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(two.argumentsJSON.utf8)),
                       .object(["n": .number(3), "s": .string("hi there")]))
        XCTAssertNil(ToolMarkup.recover("no call here"))
    }

    func testCalculatorIsExactAndRefusesAnythingElse() throws {
        for (expression, value) in [("(17.5 * 12) / 3 + 1", 71.0), ("2^10 - 2**3", 1016), ("-3^2", -9), ("10 % 4", 2),
                                    ("sqrt(16) + abs(-2) + max(1, 7, 3)", 13), ("round(pi * 100) / 100", 3.14), ("1.5e3 × 2 ÷ 4", 750),
                                    ("log(1000) + ln(e)", 4), ("pow(2, 0.5) ^ 2", 2.0000000000000004)] {
            XCTAssertEqual(try Calculator.evaluate(expression), value, accuracy: 1e-9, expression)
        }
        XCTAssertTrue(try Calculator.answer("6 * 7").contains(#""result":"42""#))
        for bad in ["", "1 +", "(1 + 2", "1 / 0", "system(1)", "2 $ 3", "import os"] {
            XCTAssertThrowsError(try Calculator.evaluate(bad), bad)
        }
    }

    func testDateDifferenceCountsAndShifts() throws {
        let zone = TimeZone(identifier: "America/Chicago")!
        let gap = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try SynapseInfo.dates(from: "2026-11-22", to: "2026-12-25", addDays: nil, zone: zone).utf8)) as? [String: Any])
        XCTAssertEqual(gap["days"] as? Int, 33)
        XCTAssertEqual(gap["to_weekday"] as? String, "Friday")
        let shifted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try SynapseInfo.dates(from: "2026-02-20", to: nil, addDays: 10, zone: zone).utf8)) as? [String: Any])
        XCTAssertEqual(shifted["date"] as? String, "2026-03-02")
        XCTAssertThrowsError(try SynapseInfo.dates(from: "next tuesday", to: "2026-01-01", addDays: nil))
        XCTAssertTrue(try SynapseInfo.dates(from: "2026-11-22", to: "2026-12-25", addDays: 14, zone: zone).contains(#""days":33"#),
                      "a difference question with a stray add_days still counts days")
    }

    func testTimeZonesByNameAbbreviationAndCity() throws {
        XCTAssertEqual(SynapseInfo.zone(named: "Tokyo")?.identifier, "Asia/Tokyo")
        XCTAssertEqual(SynapseInfo.zone(named: "new york")?.identifier, "America/New_York")
        XCTAssertEqual(SynapseInfo.zone(named: "Europe/Paris")?.identifier, "Europe/Paris")
        XCTAssertNotNil(SynapseInfo.zone(named: "pst"))
    }

    /// Cities that name no time zone go through macOS's geocoder (needs the network).
    func testTimeInACityThatNamesNoZone() async throws {
        let text = try await SynapseInfo.time(in: "Minneapolis")
        XCTAssertTrue(text.contains("America/Chicago") && text.contains(#""place":"Minneapolis""#), text)
        do { _ = try await SynapseInfo.time(in: "Qxzzyv Plorbtown"); XCTFail("no such place") } catch {
            XCTAssertTrue("\((error as? HTTPError)?.body ?? "")".contains("IANA"), "the error tells the model what to send instead")
        }
    }

    /// Chat apps show links, not tool items: audio and the video-to-be arrive as markdown links in the answer.
    func testMediaReachesChatAppsAsLinks() {
        var audio = ServerToolCall(id: "au_1", kind: .sound, arguments: "{}")
        audio.output = .media(GeneratedMedia(kind: .audio, prompt: "rain on a tin roof", url: "http://h/v1/images/files/a.mp3"))
        XCTAssertEqual(audio.markdown, "\n\n[Listen: rain on a tin roof](http://h/v1/images/files/a.mp3)\n\n")
        var video = ServerToolCall(id: "vg_1", kind: .video, arguments: "{}")
        video.output = .media(GeneratedMedia(kind: .video, prompt: "a fox [running]", url: "http://h/v1/videos/video_1/content", jobID: "video_1"))
        XCTAssertTrue(video.markdown.contains("[Video (rendering; it can take up to an hour): a fox [running](http://h/v1/videos/video_1/content)"))
        XCTAssertTrue(video.forModel.contains("rendering") && !video.forModel.contains("http"), "the model is told not to wait or repeat the link")
    }

    /// Settings saved by 0.1.9 (web search on, before audio and video existed) get the new tools; a choice made
    /// after that sticks.
    func testToolsAddedLaterStartOnButChoicesStick() throws {
        let old = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"alwaysOn":["webSearch","imageGeneration","synapse"]}"#.utf8))
        XCTAssertEqual(old.alwaysOn, [.webSearch, .imageGeneration, .synapse, .audioGeneration, .videoGeneration])
        var off = old
        off.alwaysOn.remove(.videoGeneration)
        let again = try JSONDecoder().decode(ToolSettings.self, from: try JSONEncoder().encode(off))
        XCTAssertFalse(again.alwaysOn.contains(.videoGeneration), "turned off stays off")
        XCTAssertFalse(try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"alwaysOn":[]}"#.utf8)).alwaysOn.contains(.synapse),
                       "a 0.1.9 tool turned off stays off")
    }

    func testLightestModelOfEachKind() {
        let specs = { (ids: [String]) in ids.compactMap(Catalog.spec) }
        XCTAssertEqual(ModelSpec.lightest(specs(["minimax-h3", "wan2.2-ti2v-5b", "ltx-2.3-distilled"]))?.id, "wan2.2-ti2v-5b")
        XCTAssertEqual(ModelSpec.lightest(specs(["minimax-music3-4bit", "ace-step-1.5-4bit", "stable-audio-3-small-sfx"]))?.id,
                       "stable-audio-3-small-sfx")
        XCTAssertNil(ModelSpec.lightest([]))
        let saved = try? JSONDecoder().decode(ToolSettings.self, from: Data(#"{"videoModel":"minimax-h3"}"#.utf8))
        XCTAssertEqual(saved?.videoModel, "minimax-h3")
        XCTAssertNil(saved?.soundModel)
    }

    func testImageToolPrefersTheFastModels() {
        XCTAssertEqual(ServerToolServices.preferredImageModel(["qwen-image-2.1-q4", "flux2-klein-4b", "z-image-turbo"], edit: false), "flux2-klein-4b")
        XCTAssertEqual(ServerToolServices.preferredImageModel(["qwen-image-2.1-q4", "z-image-turbo"], edit: false), "z-image-turbo")
        XCTAssertNil(ServerToolServices.preferredImageModel(["qwen-image-2.1-q4"], edit: false), "then ImageService's own choice")
        XCTAssertNil(ServerToolServices.preferredImageModel(["z-image-turbo"], edit: true), "Z-Image can't edit")
    }

    func testLocalToolsAreOnByDefaultAndSearchIsNot() throws {
        let (server, _) = try ServerTools.split(nil, settings: ToolSettings())
        XCTAssertTrue(server.synapse && server.image != nil && server.imageFromSettings)
        XCTAssertFalse(server.webSearch || server.webFetch)
        XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: Data("{}".utf8)).alwaysOn,
                       [.synapse, .imageGeneration, .audioGeneration, .videoGeneration])
        XCTAssertTrue(server.speech && server.sound && server.video && server.mediaFromSettings)
        var none = ToolSettings()
        none.alwaysOn = []
        let asked = try ServerTools.split([.object(["type": .string("audio_generation")]), .object(["type": .string("video_generation")])], settings: none).0
        XCTAssertEqual(asked.functions.map(\.name), ["generate_speech", "generate_sound", "generate_video"])
        XCTAssertFalse(asked.mediaFromSettings)
        XCTAssertFalse(try ServerTools.split([.object(["type": .string("image_generation")])]).0.imageFromSettings, "asked for, so it stays")
    }

    func testWebFetchRefusesLocalAddressesAndReadsPages() {
        for local in ["http://127.0.0.1:9000/v1/models", "http://localhost/", "http://192.168.1.1/", "http://10.0.0.2/", "http://[::1]/",
                      "http://169.254.169.254/latest", "http://printer.local/", "http://0.0.0.0/"] {
            XCTAssertFalse(WebFetch.isPublic(URL(string: local)!), local)
        }
        XCTAssertTrue(WebFetch.isPublic(URL(string: "http://93.184.215.14/")!))
        let page = WebFetch.readable("<html><head><title>Swift &amp; You</title><style>p{}</style></head><body><nav>Menu</nav><h1>Swift 6</h1><p>Released <b>today</b>.</p><script>x()</script></body></html>")
        XCTAssertEqual(page.title, "Swift & You")
        XCTAssertEqual(page.text, "Swift 6\nReleased today.")
    }

    func testTimeToolReadsTheZone() throws {
        let text = SynapseInfo.time(now: Date(timeIntervalSince1970: 1_800_000_000), zone: TimeZone(identifier: "America/New_York")!)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(o["time_zone"] as? String, "America/New_York")
        XCTAssertEqual(o["unix"] as? Int, 1_800_000_000)
        XCTAssertEqual(o["readable"] as? String, "Friday, January 15, 2027 at 3:00 AM")
    }
}
