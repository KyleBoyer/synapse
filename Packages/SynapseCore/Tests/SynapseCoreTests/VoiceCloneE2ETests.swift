import Foundation
@preconcurrency import FluidAudio
import XCTest
@testable import SynapseCore

/// Real PocketTTS cloning. SYNAPSE_E2E=1 with pocket-tts and parakeet-v3 downloaded. The reference speaker comes from
/// macOS `say`; a speaker-embedding model then checks that the clone sounds like that speaker, not like a stock voice.
final class VoiceCloneE2ETests: XCTestCase {
    /// One cloned voice spoken by every cloning model that is downloaded, through SpeechService and the shared TTS.
    func testEveryCloningModelSpeaksTheClonedVoice() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        let decoder = AudioDecoder(ffmpegURL: try TestSupport.ffmpeg())
        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        let queue = JobQueue(store: store, decoder: decoder, settings: SettingsBox(s))
        let models = ModelManager()
        let speech = SpeechService(store: store, models: models, transcribe: SpeechService.transcriber(queue))
        let work = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let ref = work.appending(path: "daniel.aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Daniel", "-o", ref.path, "Good evening. I have been walking along the coast all afternoon, and the weather "
                       + "turned out far better than the forecast suggested. Tomorrow I plan to visit the old harbour."]
        try p.run(); p.waitUntilExit()
        let voice = try await speech.createVoice(name: "Daniel", sample: ref)
        defer { Task { _ = await speech.voices.deleteVoice(voice.id) } }
        print("[clone] transcript: \(voice.transcript ?? "none")")
        XCTAssertNotNil(voice.transcript)

        let diarizer = DiarizerManager()
        diarizer.initialize(models: try await DiarizerModels.downloadIfNeeded(to: FileManager.default.temporaryDirectory.appending(path: "synapse-speaker-embedding")))
        func embedding(_ url: URL) async throws -> [Float] {
            let dir = work.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wav = try await decoder.decodeToWAV(.media(url), into: dir)
            return try diarizer.extractSpeakerEmbedding(from: PCM.floats(fromPCM16LE: try Data(contentsOf: wav).dropFirst(44)))
        }
        func cos(_ a: [Float], _ b: [Float]) -> Float {
            let dot: Float = zip(a, b).map(*).reduce(0, +)
            let na: Float = sqrt(a.map { $0 * $0 }.reduce(0, +)), nb: Float = sqrt(b.map { $0 * $0 }.reduce(0, +))
            return dot / (na * nb)
        }
        let refEmbedding = try await embedding(ref)
        let downloaded = await store.downloaded
        let cloners = ["pocket-tts", "chatterbox-turbo", "voxcpm2", "qwen3-tts-1.7b"].filter(downloaded.contains)
        XCTAssertFalse(cloners.isEmpty)
        for id in cloners {
            let spec = try XCTUnwrap(Catalog.spec(id))
            let start = Date()
            let (rate, pcm) = try await speech.synthesize(model: spec, text: "The quick brown fox jumps over the lazy dog by the river.",
                                                        voice: voice.id, speed: 1)
            var all: [Float] = [], first: Double?
            for try await chunk in pcm { first = first ?? Date().timeIntervalSince(start); all += chunk }
            let url = work.appending(path: "\(id).wav")
            try PCM.wav16(all, rate: rate).write(to: url)
            let similarity = cos(refEmbedding, try await embedding(url))
            let heard = await queue.run(JobRequest(input: .media(url), origin: .api)).transcript?.text ?? ""
            print(String(format: "[clone] %@: similarity %.2f, first audio %.1f s, %.1f s total for %.1f s @ %d Hz; heard: %@", id, similarity,
                         first ?? 0, Date().timeIntervalSince(start), Double(all.count) / Double(rate), rate, heard))
            XCTAssertGreaterThan(similarity, 0.4, id)
            XCTAssertTrue(heard.lowercased().contains("fox"), "\(id): \(heard)")
            await models.unloadAllIdle()
        }
    }

    /// Chatterbox Turbo re-speaks Samantha's recording in Daniel's cloned voice: same words, and the speaker
    /// embedding moves from Samantha to Daniel.
    func testChatterboxConvertsARecordingIntoAClonedVoice() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        guard await store.downloaded.contains("chatterbox-turbo") else { throw XCTSkip("chatterbox-turbo not downloaded") }
        let decoder = AudioDecoder(ffmpegURL: try TestSupport.ffmpeg())
        var settings = Settings()
        settings.defaultModelID = "parakeet-v3"
        let queue = JobQueue(store: store, decoder: decoder, settings: SettingsBox(settings))
        let speech = SpeechService(store: store, models: ModelManager(), transcribe: SpeechService.transcriber(queue))
        let work = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        func say(_ voice: String, _ text: String) throws -> URL {
            let url = work.appending(path: "\(voice).aiff")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", voice, "-o", url.path, text]
            try p.run(); p.waitUntilExit()
            return url
        }
        let daniel = try say("Daniel", "Good evening. I have been walking along the coast all afternoon, and the weather turned out far better than the forecast suggested.")
        let samantha = try say("Samantha", "The quick brown fox jumps over the lazy dog by the river.")
        let voice = try await speech.createVoice(name: "Daniel", sample: daniel)
        defer { Task { _ = await speech.voices.deleteVoice(voice.id) } }

        let start = Date()
        let (rate, pcm) = try await speech.convert(model: try XCTUnwrap(Catalog.spec("chatterbox-turbo")), source: samantha, voice: voice.id)
        var out: [Float] = []
        for try await f in pcm { out += f }
        let converted = work.appending(path: "converted.wav")
        try PCM.wav16(out, rate: rate).write(to: converted)

        let diarizer = DiarizerManager()
        diarizer.initialize(models: try await DiarizerModels.downloadIfNeeded(to: FileManager.default.temporaryDirectory.appending(path: "synapse-speaker-embedding")))
        func embedding(_ url: URL) async throws -> [Float] {
            let dir = work.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wav = try await decoder.decodeToWAV(.media(url), into: dir)
            return try diarizer.extractSpeakerEmbedding(from: PCM.floats(fromPCM16LE: try Data(contentsOf: wav).dropFirst(44)))
        }
        func cos(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).map(*).reduce(0, +) / (sqrt(a.map { $0 * $0 }.reduce(0, +)) * sqrt(b.map { $0 * $0 }.reduce(0, +)))
        }
        let e = try await embedding(converted)
        let toDaniel = cos(e, try await embedding(daniel)), toSamantha = cos(e, try await embedding(samantha))
        let heard = await queue.run(JobRequest(input: .media(converted), origin: .api)).transcript?.text ?? ""
        print(String(format: "[convert] %.1f s for %.1f s of audio; like Daniel %.2f, like Samantha %.2f; heard: %@",
                     Date().timeIntervalSince(start), Double(out.count) / Double(rate), toDaniel, toSamantha, heard))
        XCTAssertTrue(heard.lowercased().contains("fox"), heard)
        XCTAssertGreaterThan(toDaniel, toSamantha)
    }

    /// The mlx-audio models speak a paragraph sentence by sentence: the first sentence arrives well before the end.
    func testMLXAudioModelsStreamSentenceBySentence() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        let speech = SpeechService(store: store, models: ModelManager())
        let text = "The quick brown fox jumps over the lazy dog. It ran down to the river before noon. Then it slept in the warm sun all afternoon."
        // Qwen3-TTS speaks only cloned voices; the other two have a default voice.
        let ids = ["voxcpm2", "chatterbox-turbo"].filter(await store.downloaded.contains)
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            // Warm: the first request also starts the sidecar and loads the model.
            for try await _ in try await speech.synthesize(model: try XCTUnwrap(Catalog.spec(id)), text: "Hello.", voice: nil, speed: 1).pcm {}
            let start = Date()
            let (rate, pcm) = try await speech.synthesize(model: try XCTUnwrap(Catalog.spec(id)), text: text, voice: nil, speed: 1)
            var chunks = 0, samples = 0, first = 0.0
            for try await c in pcm where !c.isEmpty {
                if chunks == 0 { first = Date().timeIntervalSince(start) }
                chunks += 1; samples += c.count
            }
            let total = Date().timeIntervalSince(start)
            print(String(format: "[stream] %@: %d chunks, first audio %.1f s of %.1f s, %.1f s of audio", id, chunks, first, total,
                         Double(samples) / Double(rate)))
            XCTAssertGreaterThanOrEqual(chunks, 3, id)
            XCTAssertLessThan(first, total * 0.6, id)
        }
    }

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
        let voice = try await speech.createVoice(name: "Daniel", sample: reference)
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

        // Realtime sessions and Live get their TTS from the shared lease, which speaks cloned ids itself.
        let shared = try await RealtimeServices.ttsLease(id: "pocket-tts", store: store, models: ModelManager())
        var realtime: [Float] = []
        for try await chunk in shared.synthesize("The quick brown fox jumps over the lazy dog by the river.",
                                                 voice: SpeechService.voice(voice.id), speed: 1) { realtime += chunk }
        let realtimeURL = work.appending(path: "realtime.wav")
        try PCM.wav16(realtime, rate: shared.sampleRate).write(to: realtimeURL)
        let viaLease = cos(ref, try diarizer.extractSpeakerEmbedding(from: try await samples(realtimeURL)))
        print(String(format: "[clone] through the shared realtime TTS: %.2f", viaLease))
        XCTAssertGreaterThan(viaLease, alba + 0.1)

        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        let q = JobQueue(store: store, decoder: decoder, settings: SettingsBox(s))
        let heard = await q.run(JobRequest(input: .media(cloned), origin: .api)).transcript?.text ?? ""
        print("[clone] heard: \(heard)")
        XCTAssertTrue(heard.lowercased().contains("fox"), heard)
    }
}

/// Scores audio files against a reference speaker: SYNAPSE_SIM_REF=<clip> SYNAPSE_SIM_FILES=<a.wav,b.wav>.
/// A tool for comparing cloning models, not a regression test.
final class SpeakerSimilarityTool: XCTestCase {
    func testScore() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ref = env["SYNAPSE_SIM_REF"], let files = env["SYNAPSE_SIM_FILES"] else { throw XCTSkip("set SYNAPSE_SIM_REF and SYNAPSE_SIM_FILES") }
        let decoder = AudioDecoder(ffmpegURL: try TestSupport.ffmpeg())
        let work = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        func samples(_ path: String) async throws -> [Float] {
            let dir = work.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wav = try await decoder.decodeToWAV(.media(URL(fileURLWithPath: path)), into: dir)
            return PCM.floats(fromPCM16LE: try Data(contentsOf: wav).dropFirst(44))
        }
        let diarizer = DiarizerManager()
        diarizer.initialize(models: try await DiarizerModels.downloadIfNeeded(to: FileManager.default.temporaryDirectory.appending(path: "synapse-speaker-embedding")))
        let r = try diarizer.extractSpeakerEmbedding(from: try await samples(ref))
        for f in files.split(separator: ",").map(String.init) {
            let e = try diarizer.extractSpeakerEmbedding(from: try await samples(f))
            let dot: Float = zip(r, e).map(*).reduce(0, +)
            let nr: Float = sqrt(r.map { $0 * $0 }.reduce(0, +)), ne: Float = sqrt(e.map { $0 * $0 }.reduce(0, +))
            let cos = dot / (nr * ne)
            print(String(format: "[similarity] %.2f  %@", cos, (f as NSString).lastPathComponent))
        }
    }
}
