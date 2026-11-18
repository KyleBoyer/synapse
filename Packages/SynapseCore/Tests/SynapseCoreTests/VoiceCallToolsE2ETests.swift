import Foundation
import XCTest
@testable import SynapseCore

/// Tool calls in voice calls, both kinds: assembled (Qwen3.5 2B + PocketTTS) and omni (LFM3 hears and speaks itself).
/// The model must call get_weather for Paris, then speak an answer that uses the result.
/// SYNAPSE_E2E=1 with qwen3.5-2b, pocket-tts and lfm3-omni-2b downloaded.
final class VoiceCallToolsE2ETests: XCTestCase {
    func testBothKindsOfVoiceCallCallToolsThenSpeakTheResult() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root), models = ModelManager()
        let services = RealtimeServices.real(store: store, models: models, chat: ChatService(store: store, models: models))
        let weather: [String: Any] = ["type": "function", "name": "get_weather", "description": "Current weather for a city.",
                                      "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]
        // Qwen3.5 0.8B calls tools only with no system prompt, which a voice call always has; 2B and up decide themselves.
        // SYNAPSE_TOOLS_MODELS picks the models (minicpm-o-4.5 is another omni voice).
        let ids = (ProcessInfo.processInfo.environment["SYNAPSE_TOOLS_MODELS"] ?? "qwen3.5-2b,lfm3-omni-2b").split(separator: ",").map(String.init)
        for (model, question) in ids.map({ ($0, "What's the weather like in Paris right now?") }) {
            let s = RealtimeSession(model: model, services: services)
            func send(_ o: [String: Any]) async { await s.handle(try! JSONSerialization.data(withJSONObject: o)) }
            var it = s.events.makeAsyncIterator()
            /// Events up to the next response.done.
            func response() async -> [[String: Any]] {
                var out: [[String: Any]] = []
                while let d = await it.next() {
                    guard let e = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    out.append(e)
                    if e["type"] as? String == "error" { XCTFail("\(model): \(e)") }
                    if e["type"] as? String == "response.done" { break }
                }
                return out
            }
            await send(["type": "session.update", "session": ["type": "realtime", "tools": [weather],
                        "instructions": "You are a voice assistant. Use tools when they help. Answer in one short sentence."]])
            let start: Date
            if model == "minicpm-o-4.5" {
                // MiniCPM-o speaks in the caller's voice, so it needs to hear the question, as in a real call: spoken
                // audio in, and server turn detection starts the response.
                let aiff = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).aiff")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                p.arguments = ["-v", "Samantha", "-o", aiff.path, question]
                try p.run(); p.waitUntilExit()
                let dir = try TestSupport.tempDir()
                let wav = try await AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()).decodeToWAV(.media(aiff), into: dir, sampleRate: 24000)
                let pcm = try Data(contentsOf: wav).dropFirst(44) + Data(count: 24000 * 2 * 2)   // then 2 s of silence
                start = Date()
                for chunk in stride(from: 0, to: pcm.count, by: 9600) {
                    let piece = pcm[pcm.startIndex + chunk..<pcm.startIndex + min(chunk + 9600, pcm.count)]
                    await send(["type": "input_audio_buffer.append", "audio": Data(piece).base64EncodedString()])
                }
            } else {
                await send(["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                            "content": [["type": "input_text", "text": question]]]])
                start = Date()
                await send(["type": "response.create"])
            }
            let first = await response()
            let call = first.first { $0["type"] as? String == "response.function_call_arguments.done" }
            print(String(format: "[tools] %@: call %@ %@ after %.1f s", model, call?["name"] as? String ?? "none",
                         call?["arguments"] as? String ?? "", Date().timeIntervalSince(start)))
            let said = first.compactMap { ($0["type"] as? String)?.hasSuffix("transcript.delta") == true ? $0["delta"] as? String : nil }.joined()
            if call == nil { print("[tools] \(model) said instead: \(said)") }
            XCTAssertEqual(call?["name"] as? String, "get_weather", model)
            XCTAssertTrue((call?["arguments"] as? String ?? "").contains("Paris"), model)
            guard let callID = call?["call_id"] as? String else { await s.close(); continue }

            await send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID,
                        "output": #"{"city": "Paris", "temperature_c": 18, "sky": "light rain"}"#]])
            let t2 = Date()
            await send(["type": "response.create"])
            let second = await response()
            let spoken = second.filter { $0["type"] as? String == "response.output_audio.delta" }
                .reduce(0) { $0 + (Data(base64Encoded: $1["delta"] as? String ?? "")?.count ?? 0) }
            let transcript = second.compactMap { $0["type"] as? String == "response.output_audio_transcript.delta" ? $0["delta"] as? String : nil }.joined()
            print(String(format: "[tools] %@: answer in %.1f s, %.1f s of speech: %@", model, Date().timeIntervalSince(t2),
                         Double(spoken) / 48000, transcript))
            XCTAssertGreaterThan(spoken, 48000, "\(model): at least a second of speech")
            XCTAssertTrue(transcript.contains("18") || transcript.lowercased().contains("rain"), "\(model): \(transcript)")
            await s.close()
            await models.unloadAllIdle()
        }
    }
}
