import Foundation
@preconcurrency import FluidAudio
import XCTest
@testable import SynapseCore

/// Real PocketTTS cloning. SYNAPSE_E2E=1 with pocket-tts and parakeet-v3 downloaded. The reference speaker comes from
/// macOS `say`; a speaker-embedding model then checks that the clone sounds like that speaker, not like a stock voice.
final class VoiceCloneE2ETests: XCTestCase {
    func testClonedVoiceSoundsLikeTheReferenceAndSaysTheText() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        let decoder = AudioDecoder(ffmpegURL: try TestSupport.ffmpeg())
        let speech = SpeechService(store: store, models: ModelManager())
        let work = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        func say(_ voice: String, _ text: String, _ name: String) throws -> URL {
            let out = work.appending(path: "\(name).aiff")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", voice, "-o", out.path, text]
            try p.run(); p.waitUntilExit()
            return out
        }
        /// 16 kHz mono samples, what the speaker-embedding model takes.
        func samples(_ url: URL) async throws -> [Float] {
            let dir = work.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wav = try await decoder.decodeToWAV(.media(url), into: dir)
            return PCM.floats(fromPCM16LE: try Data(contentsOf: wav).dropFirst(44))
        }
        func speak(_ voice: String?, _ name: String) async throws -> URL {
            let model = try XCTUnwrap(Catalog.spec("pocket-tts"))
            let (rate, pcm) = try await speech.synthesize(model: model, text: "The quick brown fox jumps over the lazy dog by the river.",
                                                        voice: voice, speed: 1)
            var all: [Float] = []
            for try await chunk in pcm { all += chunk }
            let url = work.appending(path: "\(name).wav")
            try PCM.wav16(all, rate: rate).write(to: url)
            return url
        }

        let reference = try say("Daniel", "Good evening. I have been walking along the coast all afternoon, and the weather turned "
                                 + "out far better than the forecast suggested. Tomorrow I plan to visit the old harbour.", "daniel-ref")
        let otherDaniel = try say("Daniel", "Please remember to collect the parcels from the post office before it closes.", "daniel-2")

        let start = Date()
        let voice = try await speech.createVoice(name: "Daniel", sample: reference, consentID: nil)
        defer { Task { _ = await speech.voices.deleteVoice(voice.id) } }
        print(String(format: "[clone] %@ from %.1f s of audio in %.1f s", voice.id, voice.seconds, Date().timeIntervalSince(start)))
        let cloned = try await speak(voice.id, "clone")
        let stock = try await speak("alba", "alba")

        let models = try await DiarizerModels.downloadIfNeeded(to: FileManager.default.temporaryDirectory.appending(path: "synapse-speaker-embedding"))
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        func cos(_ a: [Float], _ b: [Float]) -> Float {
            let dot = zip(a, b).map(*).reduce(0, +)
            return dot / (sqrt(a.map { $0 * $0 }.reduce(0, +)) * sqrt(b.map { $0 * $0 }.reduce(0, +)))
        }
        let ref = try diarizer.extractSpeakerEmbedding(from: try await samples(reference))
        let same = cos(ref, try diarizer.extractSpeakerEmbedding(from: try await samples(otherDaniel)))
        let clone = cos(ref, try diarizer.extractSpeakerEmbedding(from: try await samples(cloned)))
        let alba = cos(ref, try diarizer.extractSpeakerEmbedding(from: try await samples(stock)))
        print(String(format: "[clone] similarity to the reference: same speaker %.2f, clone %.2f, stock voice %.2f", same, clone, alba))
        XCTAssertGreaterThan(clone, alba + 0.1, "the clone should sound closer to the reference than a stock voice")

        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        let q = JobQueue(store: store, decoder: decoder, settings: SettingsBox(s))
        let heard = await q.run(JobRequest(input: .media(cloned), origin: .api)).transcript?.text ?? ""
        print("[clone] heard: \(heard)")
        XCTAssertTrue(heard.lowercased().contains("fox"), heard)
    }
}
