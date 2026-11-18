import Foundation
import XCTest
@testable import SynapseCore

/// Real LFM3-Omni-2B answering in its own voice, and Gemma 4 E2B hearing audio through mlx-vlm (P5).
/// SYNAPSE_E2E=1 with lfm3-omni-2b, gemma-4-e2b and parakeet-v3 downloaded.
final class OmniVoiceE2ETests: XCTestCase {
    private var root: URL {
        ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
    }

    private func fixtureWAV(_ dir: URL) async throws -> URL {
        try await AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()).decodeToWAV(.media(TestSupport.fixture("en.m4a")), into: dir)
    }

    func testLFM3HearsAndAnswersOutLoud() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try await fixtureWAV(dir)
        let store = ModelStore(root: root), models = ModelManager()
        let spec = try XCTUnwrap(Catalog.spec("lfm3-omni-2b"))
        XCTAssertTrue(OmniVoices.canSpeak(spec))
        var start = Date()
        let voice = LeasedOmniVoice(try await OmniVoices.lease(spec, store: store, models: models))
        let load = Date().timeIntervalSince(start)
        start = Date()
        var text = "", audio: [Float] = [], rate = 24000, firstAudio: Double?
        for try await e in voice.respond([ChatMessage(role: .system, text: "You are a helpful assistant. Keep answers short."),
                                          ChatMessage(role: .user, text: "Repeat exactly what the speaker says.", audios: [wav])],
                                         options: ChatOptions(maxTokens: 256)) {
            switch e {
            case .text(let t): text += t
            case .audio(let a, let r):
                audio += a; rate = r
                if firstAudio == nil { firstAudio = Date().timeIntervalSince(start) }
            case .done, .toolCall: break
            }
        }
        let took = Date().timeIntervalSince(start)
        let seconds = Double(audio.count) / Double(rate)
        print(String(format: "[voice] load %.1f s; first audio %.2f s; %.1f s of speech in %.1f s: %@", load, firstAudio ?? -1, seconds, took, text))
        XCTAssertGreaterThan(seconds, 1)
        XCTAssertLessThan(firstAudio ?? 99, took, "speech streams before the reply is finished")

        // The speech must say it, not just the text: transcribe what the model said out loud.
        let spoken = dir.appending(path: "reply.wav")
        try PCM.wav16(audio, rate: rate).write(to: spoken)
        var s = Settings(); s.defaultModelID = "parakeet-v3"
        let q = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: SettingsBox(s), models: models)
        let heard = await q.run(JobRequest(input: .media(spoken), origin: .api)).transcript?.text ?? ""
        print("[voice] Parakeet hears the reply as: \(heard)")
        XCTAssertTrue(heard.lowercased().contains("fox"), heard)
    }

    func testGemma4HearsThroughMLXVLM() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try await fixtureWAV(dir)
        let models = ModelManager()
        let chat = ChatService(store: ModelStore(root: root), models: models)
        let spec = try XCTUnwrap(Catalog.spec("gemma-4-e2b"))
        let supported = await chat.supportsAudio(spec)
        XCTAssertTrue(supported)
        var answer = ""
        for try await e in try await chat.stream(model: spec, messages: [ChatMessage(role: .user, text: "Transcribe the audio.", audios: [wav])],
                                                 options: ChatOptions(maxTokens: 60, temperature: 0)) {
            if case .delta(let d) = e { answer += d }
        }
        print("[gemma4] \(answer)")
        try await Task.sleep(for: .milliseconds(200))
        await models.unloadAllIdle()
        XCTAssertTrue(answer.lowercased().contains("fox"), answer)
    }
}
