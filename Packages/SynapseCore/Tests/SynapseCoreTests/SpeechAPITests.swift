import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

private struct SineTTS: RealtimeTTS {
    var sampleRate: Int { 24000 }
    func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { c in
            for i in 0..<5 { c.yield((0..<2400).map { 0.4 * sin(2 * .pi * 440 * Float($0 + i * 2400) / 24000) }) }
            c.finish()
        }
    }
}

final class SpeechAPITests: XCTestCase, @unchecked Sendable {
    private func makeApp(downloaded: [String] = ["pocket-tts"]) throws -> Application<RouterResponder<SynapseContext>> {
        let store = try TestSupport.store(downloaded: downloaded)
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box,
                             engineFactory: { _, _ in FakeEngine() })
        let speech = SpeechService(store: store, encoder: AudioEncoder(ffmpegURL: try TestSupport.ffmpeg()), tts: { _ in SineTTS() })
        return Application(router: buildRouter(queue: queue, store: store, settings: box, speech: speech))
    }

    private func post(_ c: some TestClientProtocol, _ body: String, check: @escaping @Sendable (TestResponse) throws -> Void) async throws {
        try await c.execute(uri: "/v1/audio/speech", method: .post,
                            headers: [.contentType: "application/json", HTTPField.Name("Host")!: "example.test:1234"],
                            body: ByteBuffer(string: body)) { try check($0) }
    }

    func testWavStartsWithRIFF() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"model":"tts-1","voice":"alloy","input":"hi","response_format":"wav"}"#) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(r.headers[.contentType], "audio/wav")
                XCTAssertEqual(String(decoding: Data(buffer: r.body).prefix(4), as: UTF8.self), "RIFF")
            }
        }
    }

    func testPcmByteCount() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"input":"hi","response_format":"pcm"}"#) { r in
                XCTAssertEqual(r.body.readableBytes, 5 * 2400 * 2)
            }
        }
    }

    func testMp3IsDefaultAndFramed() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"model":"tts-1","voice":"alloy","input":"hi"}"#) { r in
                XCTAssertEqual(r.headers[.contentType], "audio/mpeg")
                let first = Data(buffer: r.body).first
                XCTAssertTrue(first == 0xFF || first == 0x49, "got \(String(describing: first))")  // frame sync or ID3
            }
        }
    }

    func testSSEDeltasThenDone() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"input":"hi","response_format":"pcm","stream_format":"sse"}"#) { r in
                let text = String(buffer: r.body)
                XCTAssertTrue(text.contains(#""type":"speech.audio.delta""#))
                let done = text.range(of: #""type":"speech.audio.done""#)
                XCTAssertNotNil(done)
                XCTAssertGreaterThan(done!.lowerBound, text.range(of: "speech.audio.delta")!.lowerBound)
            }
        }
    }

    func testBadRequestsUseOpenAIErrorShape() async throws {
        try await makeApp().test(.router) { c in
            for body in [#"{"input":""}"#, #"{"input":"hi","model":"nope"}"#,
                         #"{"input":"\#(String(repeating: "a", count: 4097))"}"#] {
                try await self.post(c, body) { r in
                    XCTAssertEqual(r.status, .badRequest)
                    let j = try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as! [String: Any]
                    XCTAssertNotNil((j["error"] as? [String: Any])?["message"])
                }
            }
        }
    }

    func testNoModelDownloadedIsUnavailable() async throws {
        try await makeApp(downloaded: []).test(.router) { c in
            try await self.post(c, #"{"input":"hi"}"#) { r in XCTAssertEqual(r.status, .serviceUnavailable) }
        }
    }
}
