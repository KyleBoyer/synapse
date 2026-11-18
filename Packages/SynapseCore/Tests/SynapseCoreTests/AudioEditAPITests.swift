import AVFoundation
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// `/v1/audio/enhance` and `/v1/audio/separate` with a runner that copies the input into the tracks each model writes.
final class AudioEditAPITests: XCTestCase, @unchecked Sendable {
    private func app(downloaded: [String]) throws -> some ApplicationProtocol {
        let store = try TestSupport.store(downloaded: ["parakeet-v3"] + downloaded)
        let ffmpeg = try TestSupport.ffmpeg()
        let sound = SoundService(store: store, models: ModelManager(), encoder: AudioEncoder(ffmpegURL: ffmpeg),
                                 decoder: AudioDecoder(ffmpegURL: ffmpeg), editRunner: { spec, _, input, prompt, out in
            let names = SoundService.editTask(spec) == .enhance ? ["audio"] : SoundService.needsPrompt(spec) ? ["target", "residual"] : ["speaker_1", "speaker_2"]
            XCTAssertEqual(prompt != nil, SoundService.needsPrompt(spec), spec.id)
            for n in names { try FileManager.default.copyItem(at: input, to: out.appending(path: "\(n).wav")) }
        })
        let box = SettingsBox(Settings())
        return Application(router: buildRouter(queue: JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: ffmpeg), settings: box),
                                               store: store, settings: box, sound: sound))
    }

    private func form(_ fields: [String: String]) throws -> ByteBuffer {
        var body = ByteBuffer()
        for (name, value) in fields { body.writeString("--XyZ\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n") }
        body.writeString("--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.writeBytes(try Data(contentsOf: TestSupport.fixture("en.m4a")))
        body.writeString("\r\n--XyZ--\r\n")
        return body
    }

    private func post(_ c: some TestClientProtocol, _ path: String, _ fields: [String: String],
                      check: @escaping @Sendable (TestResponse) throws -> Void) async throws {
        try await c.execute(uri: path, method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                            body: try form(fields)) { try check($0) }
    }

    func testEnhanceReturnsTheCleanedRecording() async throws {
        try await app(downloaded: ["deepfilternet-3"]).test(.router) { c in
            try await self.post(c, "/v1/audio/enhance", [:]) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(r.headers[.contentType], "audio/wav")
                let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: url) }
                try Data(buffer: r.body).write(to: url)
                let f = try AVAudioFile(forReading: url)
                XCTAssertEqual(f.processingFormat.sampleRate, 48000)
                XCTAssertGreaterThan(Double(f.length) / 48000, 1)
            }
            try await self.post(c, "/v1/audio/enhance", ["response_format": "mp3"]) { r in
                let b = Array(Data(buffer: r.body).prefix(3))
                XCTAssertTrue(b == Array("ID3".utf8) || b.first == 0xFF, "\(b)")
            }
            // Separation has no model here; a separation model is not an enhancer.
            try await self.post(c, "/v1/audio/separate", [:]) { r in XCTAssertEqual(r.status, .serviceUnavailable) }
            try await self.post(c, "/v1/audio/enhance", ["model": "sam-audio-small"]) { r in XCTAssertEqual(r.status, .badRequest) }
        }
    }

    /// Conversion needs a cloned voice id and a downloaded converting model.
    func testConvertNeedsAVoiceAndTheModel() async throws {
        try await app(downloaded: []).test(.router) { c in
            try await self.post(c, "/v1/audio/convert", [:]) { r in XCTAssertEqual(r.status, .badRequest) }
            try await self.post(c, "/v1/audio/convert", ["voice": "voice_x"]) { r in
                XCTAssertEqual(r.status, .serviceUnavailable)
                XCTAssertTrue(String(buffer: r.body).contains("not downloaded"))
            }
            try await self.post(c, "/v1/audio/convert", ["voice": "voice_x", "model": "no-such-model"]) { r in XCTAssertEqual(r.status, .badRequest) }
        }
    }

    /// A prompt picks SAM-Audio (target and residual); no prompt picks DialogueSidon (two speakers).
    func testSeparatePicksTheModelByPrompt() async throws {
        try await app(downloaded: ["sam-audio-small", "dialoguesidon"]).test(.router) { c in
            for (fields, model, names) in [(["prompt": "speech"], "sam-audio-small", ["residual", "target"]),
                                           ([:], "dialoguesidon", ["speaker_1", "speaker_2"])] {
                try await self.post(c, "/v1/audio/separate", fields) { r in
                    XCTAssertEqual(r.status, .ok)
                    let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any])
                    XCTAssertEqual(o["model"] as? String, model)
                    let tracks = o["tracks"] as? [[String: Any]] ?? []
                    XCTAssertEqual(tracks.compactMap { $0["name"] as? String }, names)
                    let wav = Data(base64Encoded: tracks.first?["audio"] as? String ?? "") ?? Data()
                    XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
                }
            }
            try await self.post(c, "/v1/audio/separate", ["model": "sam-audio-small"]) { r in
                XCTAssertEqual(r.status, .badRequest)
                XCTAssertTrue(String(buffer: r.body).contains("prompt"))
            }
        }
    }
}
