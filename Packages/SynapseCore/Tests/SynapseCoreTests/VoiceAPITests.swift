import Foundation
@preconcurrency import FluidAudio
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// Speaks a 440 Hz tone, or 880 Hz from a reference clip, so tests can tell which path ran.
private struct CloningTTS: ReferenceVoiceTTS {
    var sampleRate: Int { 24000 }
    func tone(_ hz: Float) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { c in c.yield((0..<4800).map { 0.4 * sin(2 * .pi * hz * Float($0) / 24000) }); c.finish() }
    }
    func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error> { tone(440) }
    func synthesize(_ text: String, reference: VoiceReference, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        FileManager.default.fileExists(atPath: reference.sample.path) ? tone(880) : tone(100)
    }
}

private func object(_ b: ByteBuffer) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any])
}

/// Multipart body with text fields and one file part.
private func multipart(_ fields: [String: String], file: (name: String, data: Data)?) -> (ByteBuffer, String) {
    let b = "synapse-test-boundary"
    var d = Data()
    for (k, v) in fields.sorted(by: { $0.key < $1.key }) { d += Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
    if let file {
        d += Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        d += file.data + Data("\r\n".utf8)
    }
    d += Data("--\(b)--\r\n".utf8)
    return (ByteBuffer(data: d), "multipart/form-data; boundary=\(b)")
}

private func clip(seconds: Double) -> Data {
    PCM.wav16((0..<Int(seconds * 24000)).map { 0.3 * sin(2 * .pi * 220 * Float($0) / 24000) }, rate: 24000)
}

final class VoiceAPITests: XCTestCase, @unchecked Sendable {
    private func makeApp() throws -> Application<RouterResponder<SynapseContext>> {
        let store = try TestSupport.store(downloaded: ["pocket-tts", "kokoro-82m", "qwen3-tts-1.7b"])
        let box = SettingsBox(Settings())
        let ffmpeg = try TestSupport.ffmpeg()
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: ffmpeg), settings: box, engineFactory: { _, _ in FakeEngine() })
        let speech = SpeechService(store: store, encoder: AudioEncoder(ffmpegURL: ffmpeg), decoder: AudioDecoder(ffmpegURL: ffmpeg),
                                   transcribe: { _ in "a heard transcript" },
                                   tts: { spec in spec.id == "kokoro-82m" ? FakeKokoro() as any RealtimeTTS : CloningTTS() })
        return Application(router: buildRouter(queue: queue, store: store, settings: box, speech: speech))
    }

    private func speak(_ c: some TestClientProtocol, _ body: String) async throws -> TestResponse {
        try await c.execute(uri: "/v1/audio/speech", method: .post, headers: [.contentType: "application/json"], body: ByteBuffer(string: body))
    }

    func testConsentThenVoiceThenSpeechInThatVoice() async throws {
        try await makeApp().test(.router) { c in
            let (cBody, cType) = multipart(["name": "Kyle", "language": "en-US"], file: ("recording", clip(seconds: 2)))
            let consent = try await c.execute(uri: "/v1/audio/voice_consents", method: .post, headers: [.contentType: cType], body: cBody) {
                XCTAssertEqual($0.status, .ok)
                let o = try object($0.body)
                XCTAssertEqual(o["object"] as? String, "audio.voice_consent")
                XCTAssertEqual(o["language"] as? String, "en-US")
                return try XCTUnwrap(o["id"] as? String)
            }
            try await c.execute(uri: "/v1/audio/voice_consents/\(consent)", method: .post, headers: [.contentType: "application/json"],
                                body: ByteBuffer(string: #"{"name":"Kyle (studio)"}"#)) {
                XCTAssertEqual(try object($0.body)["name"] as? String, "Kyle (studio)")
            }
            try await c.execute(uri: "/v1/audio/voice_consents", method: .get) {
                XCTAssertEqual((try object($0.body)["data"] as? [[String: Any]])?.count, 1)
            }

            let (vBody, vType) = multipart(["name": "Kyle", "consent": consent], file: ("audio_sample", clip(seconds: 3)))
            let voice = try await c.execute(uri: "/v1/audio/voices", method: .post, headers: [.contentType: vType], body: vBody) {
                XCTAssertEqual($0.status, .ok, String(buffer: $0.body))
                let o = try object($0.body)
                XCTAssertEqual(o["object"] as? String, "audio.voice")
                XCTAssertEqual(o["type"] as? String, "audio_sample")
                let id = try XCTUnwrap(o["id"] as? String)
                XCTAssertTrue(id.hasPrefix("voice_"))
                return id
            }
            try await c.execute(uri: "/v1/audio/voices", method: .get) {
                XCTAssertEqual((try object($0.body)["data"] as? [[String: Any]])?.first?["id"] as? String, voice)
            }
            // Qwen3-TTS has no stock voice, and speaks cloned ones (this one was transcribed when it was made).
            let qwenStock = try await speak(c, #"{"model":"qwen3-tts-1.7b","input":"hi","voice":"alba"}"#)
            XCTAssertEqual(qwenStock.status, .badRequest)
            let qwenClone = try await speak(c, #"{"model":"qwen3-tts-1.7b","input":"hi","voice":{"id":"\#(voice)"},"response_format":"pcm"}"#)
            XCTAssertEqual(qwenClone.status, .ok)

            // The cloned voice speaks through the clone path (880 Hz); a stock voice does not.
            func pitch(_ r: TestResponse) -> Int {
                let pcm = PCM.floats(fromPCM16LE: Data(buffer: r.body))
                return zip(pcm, pcm.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count * 24000 / max(pcm.count, 1)
            }
            let cloned = try await speak(c, #"{"input":"hi","voice":{"id":"\#(voice)"},"response_format":"pcm"}"#)
            XCTAssertEqual(cloned.status, .ok)
            XCTAssertEqual(pitch(cloned), 880, accuracy: 10)
            let stock = try await speak(c, #"{"input":"hi","voice":"alba","response_format":"pcm"}"#)
            XCTAssertEqual(pitch(stock), 440, accuracy: 10)
            // Kokoro has fixed voices.
            let kokoro = try await speak(c, #"{"model":"kokoro-82m","input":"hi","voice":"\#(voice)"}"#)
            XCTAssertEqual(kokoro.status, .badRequest)

            try await c.execute(uri: "/v1/audio/voices/\(voice)", method: .delete) {
                XCTAssertEqual(try object($0.body)["object"] as? String, "audio.voice.deleted")
            }
            let deleted = try await speak(c, #"{"input":"hi","voice":"\#(voice)"}"#)
            XCTAssertEqual(deleted.status, .badRequest)
            try await c.execute(uri: "/v1/audio/voice_consents/\(consent)", method: .delete) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/v1/audio/voice_consents/\(consent)", method: .get) { XCTAssertEqual($0.status, .notFound) }
        }
    }

    /// Realtime sessions pass the session voice through this filter: stock and cloned voices survive, OpenAI names fall back.
    func testSessionVoicesKeepClonedIds() {
        XCTAssertEqual(SpeechService.voice("alba"), "alba")
        XCTAssertEqual(SpeechService.voice("voice_abc"), "voice_abc")
        XCTAssertNil(SpeechService.voice("alloy"))
        XCTAssertNil(SpeechService.voice(nil))
    }

    func testVoicesNeedNoConsentButRefuseShortSamplesAndPromptVoices() async throws {
        try await makeApp().test(.router) { c in
            let (noConsent, t1) = multipart(["name": "X"], file: ("audio_sample", clip(seconds: 3)))
            try await c.execute(uri: "/v1/audio/voices", method: .post, headers: [.contentType: t1], body: noConsent) {
                XCTAssertEqual($0.status, .ok, String(buffer: $0.body))
            }
            let (anyConsent, t2) = multipart(["name": "Y", "consent": "cons_whatever", "transcript": "Given text."],
                                             file: ("audio_sample", clip(seconds: 3)))
            try await c.execute(uri: "/v1/audio/voices", method: .post, headers: [.contentType: t2], body: anyConsent) {
                XCTAssertEqual($0.status, .ok, String(buffer: $0.body))
            }
            let (short, t3) = multipart(["name": "X"], file: ("audio_sample", clip(seconds: 0.5)))
            try await c.execute(uri: "/v1/audio/voices", method: .post, headers: [.contentType: t3], body: short) {
                XCTAssertEqual($0.status, .badRequest)
                XCTAssertTrue(String(buffer: $0.body).contains("too short"), String(buffer: $0.body))
            }
            let (prompt, t4) = multipart(["name": "X", "type": "prompt", "prompt": "a calm narrator"], file: nil)
            try await c.execute(uri: "/v1/audio/voices", method: .post, headers: [.contentType: t4], body: prompt) {
                XCTAssertEqual($0.status, .badRequest)
            }
        }
    }

    func testVoicesKeepTheClipAndATranscript() async throws {
        let store = try TestSupport.store(downloaded: [])
        let ffmpeg = try TestSupport.ffmpeg()
        let speech = SpeechService(store: store, encoder: AudioEncoder(ffmpegURL: ffmpeg), decoder: AudioDecoder(ffmpegURL: ffmpeg),
                                   transcribe: { _ in "  heard it  " }, tts: { _ in CloningTTS() })
        let src = try TestSupport.tempDir().appending(path: "long.wav")
        try clip(seconds: 14).write(to: src)
        let heard = try await speech.createVoice(name: "Long", sample: src)
        XCTAssertEqual(heard.seconds, 10, accuracy: 0.01, "only the first 10 seconds are kept")
        XCTAssertEqual(heard.transcript, "heard it")
        let given = try await speech.createVoice(name: "Given", sample: src, transcript: "What it says.")
        XCTAssertEqual(given.transcript, "What it says.")
        let found = await speech.voices.reference(heard.id)
        let ref = try XCTUnwrap(found)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ref.sample.path))
    }
}

private struct FakeKokoro: RealtimeTTS {
    var sampleRate: Int { 24000 }
    func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { c in c.yield([Float](repeating: 0, count: 2400)); c.finish() }
    }
}
