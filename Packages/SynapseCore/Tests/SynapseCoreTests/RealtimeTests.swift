import Foundation
import Synchronization
import XCTest
@testable import SynapseCore

// MARK: fakes

private struct FakeVAD: RealtimeVAD {
    func speechProbability(_ c: [Float]) async throws -> Float { c.contains { abs($0) > 0.05 } ? 0.95 : 0.02 }
}

private actor FakeASR: RealtimeASR {
    var n = 0
    func feed(_ s: [Float]) async throws -> String { n += s.count; return n > 8000 ? "hello" : "" }
    func finish() async throws -> String { defer { n = 0 }; return n > 0 ? "hello world" : "" }
}

private struct FakeTTS: RealtimeTTS {
    var sampleRate: Int { 24000 }
    var delayMs = 0
    func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        let d = delayMs
        return AsyncThrowingStream { c in
            let t = Task {
                for _ in 0..<3 {
                    if d > 0 { try? await Task.sleep(for: .milliseconds(d)) }
                    if Task.isCancelled { break }
                    c.yield([Float](repeating: 0.3, count: 1920))
                }
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

private final class FakeLLM: RealtimeLLM, @unchecked Sendable {
    let modelID = "fake"
    var delayMs = 0
    var seen: [[ChatMessage]] = []
    func stream(_ messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        seen.append(messages)
        let d = delayMs
        // Offered tools and no result yet: call the first one, like a model that needs data.
        if let tool = options.tools.first, !(messages.last?.text.contains("<tool_response>") ?? false) {
            return AsyncThrowingStream { c in
                c.yield(.toolCall(name: tool.name, arguments: #"{"city":"Paris"}"#))
                c.yield(.done(finishReason: "stop", usage: ChatUsage(promptTokens: 1, completionTokens: 1)))
                c.finish()
            }
        }
        return AsyncThrowingStream { c in
            let t = Task {
                for part in ["Hi there. ", "How can ", "I help you today? ", "Anything else. ", "Really."] {
                    if d > 0 { try? await Task.sleep(for: .milliseconds(d)) }
                    if Task.isCancelled { break }
                    c.yield(.delta(part))
                }
                c.yield(.done(finishReason: "stop", usage: ChatUsage(promptTokens: 1, completionTokens: 1)))
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

private actor FakeDuplex: DuplexSpeechEngine {
    nonisolated var inputSampleRate: Int { 16000 }
    nonisolated var outputSampleRate: Int { 24000 }
    func push(_ samples: [Float]) async throws -> [DuplexEvent] { [.assistantText("yo"), .audio([Float](repeating: 0.2, count: 2400))] }
    func reset() async {}
    func unload() async {}
}

/// A duplex model with its own tool calling (VoiceChat): once it has tools, it calls the first one, then waits.
private actor NativeToolDuplex: DuplexSpeechEngine {
    nonisolated var inputSampleRate: Int { 16000 }
    nonisolated var outputSampleRate: Int { 24000 }
    var toolSupport: DuplexToolSupport { .native }
    var tools: [ChatTool] = [], called = false, results: [(String, String)] = []
    func setTools(_ t: [ChatTool]) { tools = t; called = false }
    func toolResult(name: String, output: String) { results.append((name, output)) }
    func push(_ samples: [Float]) async throws -> [DuplexEvent] {
        var out: [DuplexEvent] = [.audio([Float](repeating: 0.2, count: 2400))]
        if let t = tools.first, !called { called = true; out.append(.toolCall(name: t.name, arguments: #"{"city":"Paris"}"#)) }
        return out
    }
    func reset() async {}
    func unload() async {}
}

/// A duplex model that only speaks (PersonaPlex): records what it was asked to say.
private actor SpeakingDuplex: DuplexSpeechEngine {
    nonisolated var inputSampleRate: Int { 16000 }
    nonisolated var outputSampleRate: Int { 24000 }
    var toolSupport: DuplexToolSupport { .spokenResults }
    var said: [String] = []
    func say(_ text: String) { said.append(text) }
    func push(_ samples: [Float]) async throws -> [DuplexEvent] { [.audio([Float](repeating: 0.2, count: 2400))] }
    func reset() async {}
    func unload() async {}
}

/// Which recognizer and speech models a session asked the services for.
private final class Requested: @unchecked Sendable {
    private let lock = NSLock()
    private var asrModels: [String] = [], languages: [String?] = [], ttsModels: [String?] = []
    func asr(_ m: String, _ l: String?) { lock.withLock { asrModels.append(m); languages.append(l) } }
    func tts(_ m: String?) { lock.withLock { ttsModels.append(m) } }
    var seen: (asr: [String], languages: [String?], tts: [String?]) { lock.withLock { (asrModels, languages, ttsModels) } }
}

private func services(llm: FakeLLM = FakeLLM(), ttsDelay: Int = 0, voice: FakeVoice = FakeVoice(),
                      requested: Requested = Requested(), duplex: any DuplexSpeechEngine = FakeDuplex()) -> RealtimeServices {
    RealtimeServices(vad: { FakeVAD() }, asr: { m, l in requested.asr(m, l); return FakeASR() },
                     tts: { m in requested.tts(m); return FakeTTS(delayMs: ttsDelay) }, llm: { _ in llm },
                     special: { _ in RealtimeSpecialModel(duplex: duplex) }, voice: { _ in voice })
}

/// An omni model that answers in its own voice: records what it heard, returns 0.5 s of 24 kHz audio.
private final class FakeVoice: RealtimeVoiceLLM, @unchecked Sendable {
    let modelID = "lfm3-omni-2b"
    var seen: [[ChatMessage]] = []
    var heardBytes = 0
    func respond(_ messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<VoiceEvent, Error> {
        seen.append(messages)
        heardBytes = messages.last?.audios.first.flatMap { try? Data(contentsOf: $0).count } ?? 0
        if let tool = options.tools.first, !(messages.last?.text.contains("<tool_response>") ?? false) {
            return AsyncThrowingStream { c in
                c.yield(.toolCall(name: tool.name, arguments: #"{"city":"Paris"}"#))
                c.yield(.done(promptTokens: 1, generationTokens: 1))
                c.finish()
            }
        }
        return AsyncThrowingStream { c in
            c.yield(.text("I heard "))
            c.yield(.audio([Float](repeating: 0.1, count: 6000), sampleRate: 24000))
            c.yield(.text("you."))
            c.yield(.audio([Float](repeating: 0.1, count: 6000), sampleRate: 24000))
            c.yield(.done(promptTokens: 1, generationTokens: 1))
            c.finish()
        }
    }
}

private final class RTCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String: Any]] = []
    var events: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return all }
    func add(_ e: [String: Any]) { lock.lock(); all.append(e); lock.unlock() }
    var types: [String] { events.map { $0["type"] as? String ?? "" } }
    func wait(_ type: String, count: Int = 1, timeout: Double = 8) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if types.filter({ $0 == type }).count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    func first(_ type: String) -> [String: Any]? { events.first { $0["type"] as? String == type } }
}

private func start(_ s: RealtimeSession) -> RTCollector {
    let c = RTCollector()
    Task { for await d in s.events { c.add(try! JSONSerialization.jsonObject(with: d) as! [String: Any]) } }
    return c
}

private func tone(ms: Int) -> [Int16] { (0..<(24 * ms)).map { Int16(10000 * sin(Double($0) * 0.2)) } }
private func quiet(ms: Int) -> [Int16] { [Int16](repeating: 0, count: 24 * ms) }

private func feed(_ s: RealtimeSession, _ pcm: [Int16]) async {
    var i = 0
    while i < pcm.count { await s.appendAudio(pcm24k: Array(pcm[i..<min(i + 2400, pcm.count)])); i += 2400 }
}

private func send(_ s: RealtimeSession, _ obj: [String: Any]) async {
    await s.handle(try! JSONSerialization.data(withJSONObject: obj))
}

private func speak(_ s: RealtimeSession) async {
    await feed(s, quiet(ms: 300) + tone(ms: 1000) + quiet(ms: 1200))
}

final class RealtimeTests: XCTestCase {
    func testSessionCreatedAndUpdate() async throws {
        let s = RealtimeSession(model: "qwen3.5-0.8b", services: services())
        let c = start(s)
        let ok = await c.wait("session.created")
        XCTAssertTrue(ok)
        let created = await c.first("session.created")!
        XCTAssertEqual((created["session"] as! [String: Any])["type"] as? String, "realtime")
        XCTAssertNotNil(created["event_id"])
        await send(s, ["type": "session.update", "session": ["type": "realtime", "instructions": "Be terse.",
                       "audio": ["input": ["turn_detection": ["type": "server_vad", "silence_duration_ms": 300]]]]])
        let ok2 = await c.wait("session.updated")
        XCTAssertTrue(ok2)
        let updated = (await c.first("session.updated")!["session"]) as! [String: Any]
        XCTAssertEqual(updated["instructions"] as? String, "Be terse.")
        await s.close()
    }

    /// session.update picks the recognizer (input.transcription.model + language) and the speech model (output.model).
    func testSessionChoosesRecognizerAndSpeechModel() async throws {
        let requested = Requested()
        let s = RealtimeSession(model: "qwen3.5-0.8b", services: services(requested: requested))
        let c = start(s)
        await send(s, ["type": "session.update", "session": ["type": "realtime", "audio": [
            "input": ["transcription": ["model": "parakeet-v3", "language": "fr"]],
            "output": ["model": "chatterbox-turbo", "voice": "default"]]]])
        let ok = await c.wait("session.updated")
        XCTAssertTrue(ok)
        let output = (((await c.first("session.updated")!["session"]) as! [String: Any])["audio"] as! [String: Any])["output"] as! [String: Any]
        XCTAssertEqual(output["model"] as? String, "chatterbox-turbo")
        await speak(s)
        let done = await c.wait("response.done")
        XCTAssertTrue(done)
        XCTAssertEqual(requested.seen.asr, ["parakeet-v3"])
        XCTAssertEqual(requested.seen.languages, ["fr"])
        XCTAssertEqual(requested.seen.tts, ["chatterbox-turbo"])

        // A model that speaks only cloned voices refuses a stock voice; an unknown speech model is refused at once.
        await send(s, ["type": "session.update", "session": ["type": "realtime", "audio": ["output": ["model": "qwen3-tts-1.7b"]]]])
        await send(s, ["type": "response.create"])
        let failed = await c.wait("response.done", count: 2)
        XCTAssertTrue(failed)
        let errors = await c.events.filter { $0["type"] as? String == "error" }.map { "\($0)" }
        XCTAssertTrue(errors.contains { $0.contains("cloned voice") }, "\(errors)")
        await send(s, ["type": "session.update", "session": ["type": "realtime", "audio": ["output": ["model": "nope"]]]])
        let refused = await c.wait("error", count: errors.count + 1)
        XCTAssertTrue(refused)
        await s.close()
    }

    func testRecognizerResolution() throws {
        let both: Set<String> = ["parakeet-eou-120m", "parakeet-v3", "whisper-tiny"]
        XCTAssertEqual(try RealtimeServices.streamingOrFile("gpt-4o-transcribe", downloaded: both), "parakeet-eou-120m")
        XCTAssertNil(try RealtimeServices.streamingOrFile("whisper-1", downloaded: ["parakeet-v3"]), "no streaming model: the default file model")
        XCTAssertEqual(try RealtimeServices.streamingOrFile("parakeet-v3", downloaded: both), "parakeet-v3")
        XCTAssertEqual(try RealtimeServices.streamingOrFile("whisper-tiny", downloaded: both), "whisper-tiny")
        XCTAssertThrowsError(try RealtimeServices.streamingOrFile("whisper-large-v3", downloaded: both), "not downloaded")
        XCTAssertThrowsError(try RealtimeServices.streamingOrFile("qwen3.5-0.8b", downloaded: both), "not a transcription model")
    }

    func testTurnTranscriberHoldsAudioUntilTheTurnEnds() async throws {
        let heard = Mutex<[Int]>([])
        let t = TurnTranscriber { wav in
            heard.withLock { $0.append(((try? Data(contentsOf: wav).count) ?? 0) - 44) }
            return " bonjour "
        }
        let partial = try await t.feed([Float](repeating: 0.1, count: 16000))
        XCTAssertEqual(partial, "")
        _ = try await t.feed([Float](repeating: 0.1, count: 8000))
        let final = try await t.finish()
        XCTAssertEqual(final, "bonjour")
        XCTAssertEqual(heard.withLock { $0 }, [48000], "1.5 s of 16 kHz 16-bit audio in one file")
        let empty = try await t.finish()
        XCTAssertEqual(empty, "", "nothing buffered after a turn")
    }

    nonisolated(unsafe) private static let weather: [String: Any] = ["type": "function", "name": "get_weather", "description": "Current weather for a city.",
                                                 "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]

    /// Both voice-call paths: the model calls a tool (function_call item and argument events, no speech), the client
    /// returns the result, and the next response speaks with the result in the conversation.
    private func checkToolCall(model: String, llm: FakeLLM, voice: FakeVoice) async throws -> [[ChatMessage]] {
        let s = RealtimeSession(model: model, services: services(llm: llm, voice: voice))
        let c = start(s)
        await send(s, ["type": "session.update", "session": ["type": "realtime", "tools": [Self.weather], "tool_choice": "auto"]])
        await send(s, ["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "Weather in Paris?"]]]])
        await send(s, ["type": "response.create"])
        let first = await c.wait("response.done")
        XCTAssertTrue(first)
        let done = await c.first("response.function_call_arguments.done")
        XCTAssertEqual(done?["name"] as? String, "get_weather")
        XCTAssertEqual(done?["arguments"] as? String, #"{"city":"Paris"}"#)
        let callID = try XCTUnwrap(done?["call_id"] as? String)
        let output = ((await c.first("response.done")?["response"]) as? [String: Any])?["output"] as? [[String: Any]] ?? []
        XCTAssertEqual(output.last?["type"] as? String, "function_call")
        XCTAssertEqual(output.last?["call_id"] as? String, callID)
        let audioBefore = await c.events.filter { $0["type"] as? String == "response.output_audio.delta" }.count

        await send(s, ["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID,
                       "output": #"{"temperature_c": 18, "sky": "light rain"}"#]])
        await send(s, ["type": "response.create"])
        let second = await c.wait("response.done", count: 2)
        XCTAssertTrue(second)
        let audioAfter = await c.events.filter { $0["type"] as? String == "response.output_audio.delta" }.count
        XCTAssertGreaterThan(audioAfter, audioBefore, "the answer after the tool result is spoken")
        await s.close()
        return model == "lfm3-omni-2b" ? voice.seen : llm.seen
    }

    func testAssembledCallCallsToolsAndSpeaksTheResult() async throws {
        let seen = try await checkToolCall(model: "qwen3.5-0.8b", llm: FakeLLM(), voice: FakeVoice())
        let last = try XCTUnwrap(seen.last)
        XCTAssertTrue(last.contains { $0.role == .assistant && $0.text.contains("<function=get_weather>") }, "the call is in the history")
        XCTAssertTrue(last.last?.text.contains("<tool_response>") == true && last.last?.text.contains("light rain") == true)
    }

    func testOmniCallCallsToolsAndSpeaksTheResult() async throws {
        let seen = try await checkToolCall(model: "lfm3-omni-2b", llm: FakeLLM(), voice: FakeVoice())
        let last = try XCTUnwrap(seen.last)
        XCTAssertTrue(last.contains { $0.role == .assistant && $0.text.contains("<function=get_weather>") })
        XCTAssertTrue(last.last?.text.contains("light rain") == true)
    }

    func testBadJSONAndUnknownTypesProduceErrors() async throws {
        let s = RealtimeSession(services: services())
        let c = start(s)
        await s.handle(Data("not json".utf8))
        await s.handle(Data(#"{"foo":1}"#.utf8))
        await send(s, ["type": "bogus.event"])
        await send(s, ["type": "input_audio_buffer.append"])
        await send(s, ["type": "input_audio_buffer.commit"])
        let ok = await c.wait("error", count: 5)
        XCTAssertTrue(ok)
        let codes = await c.events.filter { $0["type"] as? String == "error" }.map { ($0["error"] as! [String: Any])["code"] as! String }
        XCTAssertEqual(codes, ["invalid_json", "missing_required_parameter", "unknown_event", "invalid_value", "input_audio_buffer_commit_empty"])
        await s.close()
    }

    func testVADTurnRunsCascadeInOrder() async throws {
        let llm = FakeLLM()
        let s = RealtimeSession(model: "qwen3.5-0.8b", services: services(llm: llm))
        let c = start(s)
        await speak(s)
        let ok = await c.wait("response.done")
        XCTAssertTrue(ok)
        let t = await c.types
        func idx(_ x: String) -> Int { t.firstIndex(of: x) ?? Int.max }
        XCTAssertLessThan(idx("input_audio_buffer.speech_started"), idx("input_audio_buffer.speech_stopped"))
        XCTAssertLessThan(idx("input_audio_buffer.speech_stopped"), idx("input_audio_buffer.committed"))
        XCTAssertLessThan(idx("input_audio_buffer.committed"), idx("conversation.item.input_audio_transcription.completed"))
        XCTAssertLessThan(idx("conversation.item.input_audio_transcription.completed"), idx("response.created"))
        XCTAssertLessThan(idx("response.created"), idx("response.output_audio.delta"))
        XCTAssertLessThan(idx("response.output_audio.done"), idx("response.done"))
        let done = await c.first("response.done")!["response"] as! [String: Any]
        XCTAssertEqual(done["status"] as? String, "completed")
        let completed = await c.first("conversation.item.input_audio_transcription.completed")!
        XCTAssertEqual(completed["transcript"] as? String, "hello world")
        let transcript = await c.events.filter { $0["type"] as? String == "response.output_audio_transcript.delta" }.map { $0["delta"] as! String }.joined()
        XCTAssertTrue(transcript.hasPrefix("Hi there."))
        let audio = await c.events.filter { $0["type"] as? String == "response.output_audio.delta" }
        let bytes = Data(base64Encoded: audio[0]["delta"] as! String)!
        XCTAssertEqual(bytes.count, 3840)
        XCTAssertEqual(llm.seen.last?.last?.text, "hello world")
        let lat = await s.lastFirstAudioLatency
        XCTAssertNotNil(lat)
        await s.close()
    }

    /// Stage B: an omni model that speaks hears the utterance itself and answers in its own voice, with no TTS.
    func testSpeakingOmniModelHearsTheTurnAndAnswersInItsOwnVoice() async throws {
        let llm = FakeLLM(), voice = FakeVoice()
        let s = RealtimeSession(model: "lfm3-omni-2b", services: services(llm: llm, voice: voice))
        let c = start(s)
        await speak(s)
        let ok = await c.wait("response.done")
        XCTAssertTrue(ok)
        let last = try XCTUnwrap(voice.seen.last?.last)
        XCTAssertEqual(last.role, .user)
        XCTAssertEqual(last.text, "", "the model hears the turn instead of reading its transcript")
        XCTAssertEqual(last.audios.count, 1)
        XCTAssertGreaterThan(voice.heardBytes, 44, "a WAV with samples, not just a header")
        XCTAssertTrue(llm.seen.isEmpty, "the cascade's chat model is not used")
        let transcript = c.events.filter { $0["type"] as? String == "response.output_audio_transcript.delta" }.map { $0["delta"] as! String }.joined()
        XCTAssertEqual(transcript, "I heard you.")
        let audioBytes = c.events.filter { $0["type"] as? String == "response.output_audio.delta" }
            .reduce(0) { $0 + (Data(base64Encoded: $1["delta"] as! String)?.count ?? 0) }
        XCTAssertGreaterThan(audioBytes, 0)
        let done = c.first("response.done")?["response"] as? [String: Any]
        XCTAssertEqual(done?["status"] as? String, "completed")
        await s.close()
    }

    func testTextOnlyModality() async throws {
        let s = RealtimeSession(services: services())
        let c = start(s)
        await send(s, ["type": "session.update", "session": ["type": "realtime", "output_modalities": ["text"]]])
        await speak(s)
        let ok = await c.wait("response.done")
        XCTAssertTrue(ok)
        let t = await c.types
        XCTAssertTrue(t.contains("response.output_text.delta"))
        XCTAssertTrue(t.contains("response.output_text.done"))
        XCTAssertFalse(t.contains("response.output_audio.delta"))
        await s.close()
    }

    func testBargeInCancelsResponse() async throws {
        let llm = FakeLLM()
        llm.delayMs = 150
        let s = RealtimeSession(services: services(llm: llm, ttsDelay: 150))
        let c = start(s)
        await speak(s)
        let ok = await c.wait("response.output_audio.delta")
        XCTAssertTrue(ok)
        await feed(s, tone(ms: 600))   // user talks over the reply
        let done = await c.wait("response.done")
        XCTAssertTrue(done)
        let resp = await c.first("response.done")!["response"] as! [String: Any]
        XCTAssertEqual(resp["status"] as? String, "cancelled")
        XCTAssertEqual((resp["status_details"] as? [String: Any])?["reason"] as? String, "turn_detected")
        let t = await c.types
        XCTAssertEqual(t.filter { $0 == "input_audio_buffer.speech_started" }.count, 2)
        let after = t[(t.firstIndex(of: "response.done")!)...]
        XCTAssertFalse(after.contains("response.output_audio.delta"))
        await s.close()
    }

    func testTranscriptionSessionOnlyTranscribes() async throws {
        let s = RealtimeSession(transcriptionOnly: true, services: services())
        let c = start(s)
        await speak(s)
        let ok = await c.wait("conversation.item.input_audio_transcription.completed")
        XCTAssertTrue(ok)
        let t = await c.types
        XCTAssertFalse(t.contains("response.created"))
        XCTAssertTrue(t.contains("conversation.item.input_audio_transcription.delta"))
        let created = await c.first("session.created")!["session"] as! [String: Any]
        XCTAssertEqual(created["type"] as? String, "transcription")
        await s.close()
    }

    func testManualCommitThenResponseCreate() async throws {
        let s = RealtimeSession(services: services())
        let c = start(s)
        await send(s, ["type": "session.update", "session": ["type": "realtime", "audio": ["input": ["turn_detection": NSNull()]]]])
        await feed(s, tone(ms: 1000))
        await send(s, ["type": "input_audio_buffer.commit"])
        let ok = await c.wait("conversation.item.input_audio_transcription.completed")
        XCTAssertTrue(ok)
        var t = await c.types
        XCTAssertFalse(t.contains("response.created"))
        await send(s, ["type": "response.create"])
        let done = await c.wait("response.done")
        XCTAssertTrue(done)
        t = await c.types
        XCTAssertFalse(t.contains("input_audio_buffer.speech_started"))
        await s.close()
    }

    func testTranslationUsesInterpreterPrompt() async throws {
        let llm = FakeLLM()
        let s = RealtimeSession(services: services(llm: llm))
        let c = start(s)
        await send(s, ["type": "session.update", "session": ["type": "realtime", "translation_language": "French"]])
        await speak(s)
        let ok = await c.wait("response.done")
        XCTAssertTrue(ok)
        let m = llm.seen.last!
        XCTAssertEqual(m.count, 2)
        XCTAssertTrue(m[0].text.contains("French"))
        XCTAssertEqual(m[1].text, "hello world")
        await s.close()
    }

    func testConversationItemCreateFeedsContext() async throws {
        let llm = FakeLLM()
        let s = RealtimeSession(services: services(llm: llm))
        let c = start(s)
        await send(s, ["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "What is two plus two?"]]]])
        await send(s, ["type": "response.create"])
        let ok = await c.wait("response.done")
        XCTAssertTrue(ok)
        XCTAssertEqual(llm.seen.last?.last?.text, "What is two plus two?")
        let t = await c.types
        XCTAssertTrue(t.contains("conversation.item.added"))
        await s.close()
    }

    /// Camera frames (P6): an image-only item joins the user's next words, and only the latest two frames stay.
    func testInputImageItemsReachTheModel() async throws {
        let llm = FakeLLM()
        let s = RealtimeSession(services: services(llm: llm))
        let c = start(s)
        let png = "data:image/png;base64," + Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        func frame() async {
            await send(s, ["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                           "content": [["type": "input_image", "image_url": png]]]])
        }
        await frame()
        await send(s, ["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "What do you see?"]]]])
        await send(s, ["type": "response.create"])
        let ok = await c.wait("response.done")
        XCTAssertTrue(ok)
        let users = llm.seen.last?.filter { $0.role == .user } ?? []
        XCTAssertEqual(users.map(\.text), ["What do you see?"])
        XCTAssertEqual(users.map(\.images.count), [1])

        for _ in 0..<3 { await frame() }
        await send(s, ["type": "response.create"])
        _ = await c.wait("response.done", count: 2)
        let all = llm.seen.last ?? []
        XCTAssertEqual(all.reduce(0) { $0 + $1.images.count }, RealtimeSession.maxImageItems)
        XCTAssertEqual(all.last?.text, "(camera frame)")

        await send(s, ["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                       "content": [["type": "input_image", "image_url": "https://example.com/a.png"]]]])
        let refused = await c.wait("error")
        XCTAssertTrue(refused)
        await s.close()
    }

    func testDuplexModelStreamsAudioWithoutCascade() async throws {
        let s = RealtimeSession(model: "voicechat-11b", services: services())
        let c = start(s)
        await feed(s, tone(ms: 300))
        let ok = await c.wait("response.output_audio.delta")
        XCTAssertTrue(ok)
        let t = await c.types
        XCTAssertFalse(t.contains("input_audio_buffer.speech_started"))
        XCTAssertTrue(t.contains("response.output_audio_transcript.delta"))
        await s.close()
        let closed = await c.wait("response.done")
        XCTAssertTrue(closed)
        let t2 = await c.types
        XCTAssertEqual(t2.last, "response.done")
    }

    /// Starts a duplex session with the weather tool, waits for its call, and returns the result for it.
    private func duplexCall(_ engine: any DuplexSpeechEngine, llm: FakeLLM = FakeLLM(), audio: [Int16]) async throws -> RealtimeSession {
        let s = RealtimeSession(model: engine is SpeakingDuplex ? "personaplex-7b" : "voicechat-11b", services: services(llm: llm, duplex: engine))
        let c = start(s)
        await send(s, ["type": "session.update", "session": ["type": "realtime", "tools": [Self.weather]]])
        await feed(s, audio)
        let called = await c.wait("response.function_call_arguments.done")
        XCTAssertTrue(called)
        let done = await c.first("response.function_call_arguments.done")
        XCTAssertEqual(done?["name"] as? String, "get_weather")
        XCTAssertEqual(done?["arguments"] as? String, #"{"city":"Paris"}"#)
        let callID = try XCTUnwrap(done?["call_id"] as? String)
        await send(s, ["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID,
                       "output": #"{"sky": "light rain"}"#]])
        await send(s, ["type": "response.create"])
        try await Task.sleep(for: .milliseconds(300))
        let errors = await c.types.filter { $0 == "error" }
        XCTAssertEqual(errors, [], "response.create after a tool result is fine in a duplex call")
        return s
    }

    func testNativeDuplexCallsToolsAndHearsTheResult() async throws {
        let engine = NativeToolDuplex()
        let s = try await duplexCall(engine, audio: tone(ms: 200))
        let tools = await engine.tools.map(\.name), results = await engine.results
        XCTAssertEqual(tools, ["get_weather"])
        XCTAssertEqual(results.first?.0, "get_weather")
        XCTAssertEqual(results.first?.1, #"{"sky": "light rain"}"#)
        await s.close()
    }

    func testSpokenResultsDuplexDecidesWithChatModelAndSpeaksTheAnswer() async throws {
        let engine = SpeakingDuplex(), llm = FakeLLM()
        let s = try await duplexCall(engine, llm: llm, audio: quiet(ms: 300) + tone(ms: 1000) + quiet(ms: 1200))
        XCTAssertEqual(llm.seen.first?.last?.text, "hello world", "the chat model reads the transcribed turn")
        var said: [String] = []
        for _ in 0..<50 where said.isEmpty { said = await engine.said; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(said.first?.hasPrefix("Hi there."), true, "the answer goes to the duplex model to say")
        XCTAssertTrue(llm.seen.last?.last?.text.contains("light rain") == true)
        await s.close()
    }

    func testSentenceSplitter() {
        var sp = SentenceSplitter()
        var out = sp.feed("Pi is 3.")
        out += sp.feed("14 roughly. Next *one* here")
        XCTAssertEqual(out, ["Pi is 3.14 roughly."])
        XCTAssertEqual(sp.flush(), "Next one here")
    }
}
