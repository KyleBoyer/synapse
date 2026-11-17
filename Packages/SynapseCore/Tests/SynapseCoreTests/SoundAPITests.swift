import AVFoundation
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

private func json(_ o: [String: Any]) -> ByteBuffer { ByteBuffer(data: try! JSONSerialization.data(withJSONObject: o)) }

final class SoundAPITests: XCTestCase {
    private func app() throws -> some ApplicationProtocol {
        let store = try TestSupport.store(downloaded: ["parakeet-v3", "stable-audio-3-small-sfx"])
        let sound = SoundService(store: store, models: ModelManager(), encoder: AudioEncoder(ffmpegURL: try TestSupport.ffmpeg()),
                                 engineFactory: { _, _ in MockSoundEngine() })
        let box = SettingsBox(Settings())
        return Application(router: buildRouter(queue: JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: box),
                                               store: store, settings: box, sound: sound))
    }

    func testWAVKeepsStereoAndMP3Encodes() async throws {
        try await app().test(.router) { c in
            try await c.execute(uri: "/v1/audio/generations", method: .post, headers: [.contentType: "application/json"],
                                body: json(["prompt": "a dog barking", "seconds": 2])) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(r.headers[.contentType], "audio/wav")
                let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: url) }
                try Data(buffer: r.body).write(to: url)
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(file.processingFormat.channelCount, 2)
                XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 2, accuracy: 0.05)
            }
            try await c.execute(uri: "/v1/audio/generations", method: .post, headers: [.contentType: "application/json"],
                                body: json(["prompt": "rain", "seconds": 1, "response_format": "mp3"])) { r in
                let b = Array(Data(buffer: r.body).prefix(3))
                XCTAssertTrue(b == Array("ID3".utf8) || b.first == 0xFF, "\(b)")
            }
        }
    }

    func testBadRequests() async throws {
        try await app().test(.router) { c in
            for bad: [String: Any] in [["seconds": 2], ["prompt": "x", "seconds": 0], ["prompt": "x", "seconds": 121],
                                       ["prompt": "x", "model": "qwen3.5-0.8b"], ["prompt": "x", "response_format": "ogg"]] {
                try await c.execute(uri: "/v1/audio/generations", method: .post, headers: [.contentType: "application/json"], body: json(bad)) { r in
                    XCTAssertEqual(r.status, .badRequest, "\(bad)")
                }
            }
        }
    }
}

/// Real Stable Audio 3. SYNAPSE_E2E=1 with stable-audio-3-small-sfx downloaded (gated on Hugging Face).
final class SoundE2ETests: XCTestCase {
    func testDogBark() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        guard await store.folder(for: "stable-audio-3-small-sfx") != nil else { throw XCTSkip("stable-audio-3-small-sfx is not downloaded") }
        let sound = SoundService(store: store, models: ModelManager())
        let spec = try await sound.resolve("stable-audio-3-small-sfx")
        let start = Date()
        let clip = try await sound.generate(model: spec, prompt: "a dog barking", seconds: 3, seed: 1)
        let rms = sqrt(clip.mono.reduce(0) { $0 + $1 * $1 } / Float(max(clip.mono.count, 1)))
        print(String(format: "[sound] %.2f s of audio at %d Hz in %.1f s, rms %.4f", clip.seconds, clip.sampleRate, Date().timeIntervalSince(start), rms))
        XCTAssertEqual(clip.seconds, 3, accuracy: 0.5)
        XCTAssertGreaterThan(rms, 0.001)
    }
}
