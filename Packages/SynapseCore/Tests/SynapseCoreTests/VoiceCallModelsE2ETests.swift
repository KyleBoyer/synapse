import Foundation
import XCTest
@testable import SynapseCore

/// A realtime voice call with the recognizer and voice chosen per session: a French question recognized turn by turn
/// (Parakeet v3), answered by Qwen3.5 and spoken by VoxCPM2, then heard back. SYNAPSE_E2E=1 with silero-vad,
/// parakeet-v3, qwen3.5-0.8b and voxcpm2 downloaded.
final class VoiceCallModelsE2ETests: XCTestCase {
    func testFrenchCallWithAFileRecognizerAndAnotherVoiceModel() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root), models = ModelManager()
        let decoder = AudioDecoder(ffmpegURL: try TestSupport.ffmpeg())
        var settings = Settings()
        settings.defaultModelID = "parakeet-v3"
        let queue = JobQueue(store: store, decoder: decoder, settings: SettingsBox(settings), models: models)
        let s = RealtimeSession(model: "qwen3.5-0.8b", services: .real(store: store, models: models,
            chat: ChatService(store: store, models: models), transcribe: RealtimeServices.turnTranscriber(queue)))
        func send(_ o: [String: Any]) async { await s.handle(try! JSONSerialization.data(withJSONObject: o)) }

        // The question, as 24 kHz PCM16 (the session's default input rate).
        let work = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let aiff = work.appending(path: "q.aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Eddy (French (France))", "-o", aiff.path, "Quelle est la capitale de l'Allemagne ?"]
        try p.run(); p.waitUntilExit()
        let wav16 = try await decoder.decodeToWAV(.media(aiff), into: work)
        let question = PCM.floats(fromPCM16LE: try Data(contentsOf: wav16).dropFirst(44))
        let up = StreamResampler(from: 16000, to: 24000)
        let pcm24 = PCM.pcm16LE(from: up.convert(question + [Float](repeating: 0, count: 16000 * 2)))

        await send(["type": "session.update", "session": ["type": "realtime",
            "instructions": "Réponds en français, en une phrase courte.",
            "audio": ["input": ["transcription": ["model": "parakeet-v3", "language": "fr"],
                                "turn_detection": ["type": "server_vad", "silence_duration_ms": 500]],
                      "output": ["model": "voxcpm2"]]]])
        for i in stride(from: 0, to: pcm24.count, by: 9600) {
            await send(["type": "input_audio_buffer.append", "audio": pcm24[i..<min(i + 9600, pcm24.count)].base64EncodedString()])
        }
        let start = Date()
        var heardQuestion = "", answer = "", audio = Data(), firstAudio: Double?
        for await data in s.events {
            guard let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = e["type"] as? String else { continue }
            switch t {
            case "conversation.item.input_audio_transcription.completed": heardQuestion = e["transcript"] as? String ?? ""
            case "response.output_audio_transcript.delta": answer += e["delta"] as? String ?? ""
            case "response.output_audio.delta":
                firstAudio = firstAudio ?? Date().timeIntervalSince(start)
                audio += Data(base64Encoded: e["delta"] as? String ?? "") ?? Data()
            case "error": XCTFail("\(e)")
            default: break
            }
            if t == "response.done" || t == "error" { break }
        }
        await s.close()
        let reply = work.appending(path: "reply.wav")
        try PCM.wav16(PCM.floats(fromPCM16LE: audio), rate: 24000).write(to: reply)
        let heardReply = try await queue.transcribeNow(.media(reply), modelID: "parakeet-v3", language: "fr").text
        print("[call] heard question: \(heardQuestion)")
        print(String(format: "[call] answer: %@ (first audio %.1f s, %.1f s of audio)", answer, firstAudio ?? -1, Double(audio.count) / 48000))
        print("[call] reply heard back: \(heardReply)")
        XCTAssertTrue(heardQuestion.lowercased().contains("capitale"), heardQuestion)
        XCTAssertTrue(answer.lowercased().contains("berlin"), answer)
        XCTAssertTrue(heardReply.lowercased().contains("berlin"), heardReply)
        await models.unloadAllIdle()
    }
}
