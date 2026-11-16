import Foundation
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

private func services(llm: FakeLLM = FakeLLM(), ttsDelay: Int = 0) -> RealtimeServices {
    RealtimeServices(vad: { FakeVAD() }, asr: { FakeASR() }, tts: { FakeTTS(delayMs: ttsDelay) }, llm: { _ in llm },
                     special: { _ in RealtimeSpecialModel(duplex: FakeDuplex()) })
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

    func testSentenceSplitter() {
        var sp = SentenceSplitter()
        var out = sp.feed("Pi is 3.")
        out += sp.feed("14 roughly. Next *one* here")
        XCTAssertEqual(out, ["Pi is 3.14 roughly."])
        XCTAssertEqual(sp.flush(), "Next one here")
    }
}
