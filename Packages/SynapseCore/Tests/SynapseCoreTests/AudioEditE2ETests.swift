import AVFoundation
import Foundation
import XCTest
@testable import SynapseCore

/// Real audio-to-audio models through SoundService. SYNAPSE_E2E=1 with parakeet-v3 and any of deepfilternet-3,
/// nemotron-reuse, sam-audio-small, dialoguesidon downloaded (each test skips models that are not).
final class AudioEditE2ETests: XCTestCase {
    private var store: ModelStore!
    private var sound: SoundService!
    private var queue: JobQueue!
    private var work: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        store = ModelStore(root: root)
        let decoder = AudioDecoder(ffmpegURL: try TestSupport.ffmpeg())
        sound = SoundService(store: store, models: ModelManager(), decoder: decoder)
        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        queue = JobQueue(store: store, decoder: decoder, settings: SettingsBox(s))
        work = try TestSupport.tempDir()
    }

    override func tearDown() async throws { if let work { try? FileManager.default.removeItem(at: work) } }

    private func downloaded(_ ids: [String]) async throws -> [ModelSpec] {
        let have = await store.downloaded
        let specs = ids.filter(have.contains).compactMap(Catalog.spec)
        if specs.isEmpty { throw XCTSkip("none of \(ids) downloaded") }
        return specs
    }

    /// macOS `say` at 48 kHz mono, with `lead` seconds of silence first.
    private func speech(_ text: String, voice: String = "Samantha", lead: Double = 1) throws -> [Float] {
        let aiff = work.appending(path: "\(UUID().uuidString).caf")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", aiff.path, "--data-format=LEF32@48000", text]
        try p.run(); p.waitUntilExit()
        let f = try AVAudioFile(forReading: aiff, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return [Float](repeating: 0, count: Int(lead * 48000)) + Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    private func write(_ x: [Float], _ name: String) throws -> URL {
        let url = work.appending(path: name)
        try PCM.wav16(x, rate: 48000).write(to: url)
        return url
    }

    private func heard(_ clip: SoundClip, _ name: String) async throws -> String {
        let url = work.appending(path: name)
        try clip.wav.write(to: url)
        return await queue.run(JobRequest(input: .media(url), origin: .api)).transcript?.text ?? ""
    }

    private func rms(_ x: ArraySlice<Float>) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot() }

    /// Speech under steady noise: the noise-only lead-in gets much quieter and the words survive.
    func testEnhancersRemoveNoiseAndKeepTheWords() async throws {
        let clean = try speech("The quick brown fox jumps over the lazy dog by the river.")
        var g = SystemRandomNumberGenerator()
        let noisy = clean.map { $0 + Float.random(in: -0.08...0.08, using: &g) }
        let input = try write(noisy, "noisy.wav")
        for spec in try await downloaded(["deepfilternet-3", "nemotron-reuse"]) {
            let start = Date()
            let tracks = try await sound.edit(model: spec, input: input, prompt: nil)
            let out = try XCTUnwrap(tracks.first).clip
            let lead = Int(0.8 * Double(out.sampleRate))
            let before = rms(noisy[0..<Int(0.8 * 48000)]), after = rms(out.mono[0..<lead])
            let text = try await heard(out, "\(spec.id).wav")
            print(String(format: "[enhance] %@: %.1f s; lead-in noise %.4f -> %.4f (%.1f dB); heard: %@", spec.id, Date().timeIntervalSince(start),
                         before, after, 20 * log10(before / max(after, 1e-6)), text))
            XCTAssertEqual(tracks.map(\.name), ["audio"])
            XCTAssertLessThan(after, before / 4, "\(spec.id) removes at least 12 dB of noise")
            XCTAssertTrue(text.lowercased().contains("fox"), "\(spec.id): \(text)")
        }
    }

    /// Speech over a loud tone; SAM-Audio pulls the speech out when asked for it.
    func testSAMAudioSeparatesTheDescribedSound() async throws {
        let voice = try speech("The quick brown fox jumps over the lazy dog by the river.")
        let mix = voice.enumerated().map { $0.element + 0.3 * sin(2 * .pi * 220 * Float($0.offset) / 48000) }
        let input = try write(mix, "mix.wav")
        for spec in try await downloaded(["sam-audio-small"]) {
            let start = Date()
            let tracks = try await sound.edit(model: spec, input: input, prompt: "speech")
            XCTAssertEqual(tracks.map(\.name), ["residual", "target"])
            let target = try XCTUnwrap(tracks.last).clip
            let text = try await heard(target, "target.wav")
            print(String(format: "[separate] %@: %.1f s; target %.1f s; heard: %@", spec.id, Date().timeIntervalSince(start), target.seconds, text))
            XCTAssertTrue(text.lowercased().contains("fox"), text)
        }
    }

    /// Two people, one after the other; DialogueSidon gives each their own track.
    func testDialogueSidonSplitsTwoSpeakers() async throws {
        let a = try speech("Hello, how are you today? I hope the weather is nice where you are.")
        let b = try speech("I am fine, thank you very much. It has been raining all morning here.", voice: "Daniel", lead: 0.3)
        let input = try write(a + b, "dialogue.wav")
        for spec in try await downloaded(["dialoguesidon"]) {
            let start = Date()
            let tracks = try await sound.edit(model: spec, input: input, prompt: nil)
            XCTAssertEqual(tracks.map(\.name), ["speaker_1", "speaker_2"])
            var texts: [String] = []
            for t in tracks { texts.append(try await heard(t.clip, "\(t.name).wav").lowercased()) }
            print(String(format: "[separate] %@: %.1f s; %@", spec.id, Date().timeIntervalSince(start), texts.joined(separator: " | ")))
            // Each speaker's words land on one track and not the other.
            let hello = texts.firstIndex { $0.contains("hello") }, raining = texts.firstIndex { $0.contains("raining") }
            XCTAssertNotNil(hello); XCTAssertNotNil(raining)
            XCTAssertNotEqual(hello, raining)
        }
    }
}
