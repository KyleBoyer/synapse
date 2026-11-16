import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

actor FakeEngine: TranscriptionEngine {
    func transcribe(wav: URL, language: String?, task: TaskKind, progress: @escaping @Sendable (Double?) -> Void) async throws -> Transcript {
        Transcript(language: "en", duration: 2, segments: [Segment(start: 0, end: 2, text: "Hello world.")])
    }
    func detectLanguage(wav: URL) async throws -> (code: String, confidence: Double) { ("en", 0.9) }
}

final class RoutesTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = try TestSupport.tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func fixture(_ name: String) throws -> URL { TestSupport.fixture(name) }

    private func makeApp(configure: (inout Settings) -> Void = { _ in }) throws -> (Application<RouterResponder<SynapseContext>>, SettingsBox) {
        let ffmpeg = try TestSupport.ffmpeg()
        let store = try TestSupport.store(downloaded: ["parakeet-v3"])
        var s = Settings()
        configure(&s)
        let box = SettingsBox(s)
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: ffmpeg), settings: box,
                             engineFactory: { _, _ in FakeEngine() })
        return (Application(router: buildRouter(queue: queue, store: store, settings: box)), box)
    }

    /// Hand-built multipart; `partContentType: nil` reproduces python-requests (Bazarr).
    private func multipart(file: String, data: Data, filename: String = "audio.bin", partContentType: String?,
                           fields: [String: String] = [:]) -> (ByteBuffer, String) {
        let b = "XBOUNDARY"
        var d = Data()
        for (k, v) in fields { d += Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
        d += Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(file)\"; filename=\"\(filename)\"\r\n".utf8)
        if let ct = partContentType { d += Data("Content-Type: \(ct)\r\n".utf8) }
        d += Data("\r\n".utf8) + data + Data("\r\n--\(b)--\r\n".utf8)
        return (ByteBuffer(data: d), "multipart/form-data; boundary=\(b)")
    }

    func testHealth() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { c in
            try await c.execute(uri: "/health", method: .get) { XCTAssertEqual($0.status, .ok) }
        }
    }

    func testModelsListsDownloadedOnly() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { c in
            try await c.execute(uri: "/v1/models", method: .get) {
                let body = String(buffer: $0.body)
                XCTAssertTrue(body.contains("parakeet-v3"))
                XCTAssertFalse(body.contains("whisper-tiny"))
            }
        }
    }

    func testTranscriptionsSRTAndWhisper1Alias() async throws {
        let (app, _) = try makeApp()
        let audio = try Data(contentsOf: fixture("en.m4a"))
        let (body, ct) = multipart(file: "file", data: audio, filename: "en.m4a", partContentType: "audio/mp4",
                                   fields: ["response_format": "srt", "model": "whisper-1"])
        try await app.test(.router) { c in
            try await c.execute(uri: "/v1/audio/transcriptions", method: .post, headers: [.contentType: ct], body: body) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertTrue(String(buffer: $0.body).hasPrefix("1\n00:00:"))
            }
        }
    }

    func testUnknownModelIs400() async throws {
        let (app, _) = try makeApp()
        let (body, ct) = multipart(file: "file", data: try Data(contentsOf: fixture("en.m4a")), partContentType: nil, fields: ["model": "nope"])
        try await app.test(.router) { c in
            try await c.execute(uri: "/v1/audio/transcriptions", method: .post, headers: [.contentType: ct], body: body) {
                XCTAssertEqual($0.status, .badRequest)
                XCTAssertTrue(String(buffer: $0.body).contains("invalid_request_error"))
            }
        }
    }

    func testASRBazarrShape() async throws {
        let (app, _) = try makeApp()
        let (body, ct) = multipart(file: "audio_file", data: try Data(contentsOf: fixture("en.pcm")), partContentType: nil)
        try await app.test(.router) { c in
            try await c.execute(uri: "/asr?output=srt&encode=false&language=en", method: .post, headers: [.contentType: ct], body: body) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual($0.headers[.contentType], "text/plain")
                XCTAssertEqual($0.headers[HTTPField.Name("Asr-Engine")!], "synapse")
                XCTAssertTrue(($0.headers[.contentDisposition] ?? "").contains("audio.srt"))
                XCTAssertTrue(String(buffer: $0.body).hasPrefix("1\n00:00:"))
            }
        }
    }

    func testDetectLanguageWithoutWhisperIsUnd() async throws {
        let (app, _) = try makeApp()
        let (body, ct) = multipart(file: "audio_file", data: try Data(contentsOf: fixture("en.pcm")), partContentType: nil)
        try await app.test(.router) { c in
            try await c.execute(uri: "/detect-language?encode=false", method: .post, headers: [.contentType: ct], body: body) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertTrue(String(buffer: $0.body).contains("\"language_code\":\"und\""))
            }
        }
    }

    func testJobsPolicyAndSidecar() async throws {
        let dir = try tempDir()
        let media = dir.appendingPathComponent("movie.m4a")
        try FileManager.default.copyItem(at: fixture("en.m4a"), to: media)
        let (app, _) = try makeApp { $0.libraryRoots = [dir.path] }
        let outside = try tempDir().appendingPathComponent("x.m4a")
        try FileManager.default.copyItem(at: fixture("en.m4a"), to: outside)

        try await app.test(.router) { c in
            let json: HTTPFields = [.contentType: "application/json"]
            try await c.execute(uri: "/v1/jobs", method: .post, headers: json, body: ByteBuffer(string: "{\"path\":\"\(outside.path)\"}")) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await c.execute(uri: "/v1/jobs", method: .post, headers: json, body: ByteBuffer(string: "{\"path\":\"\(dir.path)/missing.m4a\"}")) {
                XCTAssertEqual($0.status, .notFound)
            }
            var id = ""
            try await c.execute(uri: "/v1/jobs", method: .post, headers: json, body: ByteBuffer(string: "{\"path\":\"\(media.path)\"}")) {
                XCTAssertEqual($0.status, .accepted)
                id = try JSONDecoder().decode([String: String].self, from: Data(buffer: $0.body))["id"] ?? ""
            }
            var status = ""
            for _ in 0..<100 where status != "done" {
                try await c.execute(uri: "/v1/jobs/\(id)", method: .get) {
                    status = (try? JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as? [String: Any])?["status"] as? String ?? ""
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(status, "done")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("movie.en.srt").path))
        }
    }

    func testLANAuth() async throws {
        let (app, box) = try makeApp { $0.allowLAN = true }
        let key = box.current.apiKey
        try await app.test(.router) { c in
            try await c.execute(uri: "/v1/models", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            try await c.execute(uri: "/health", method: .get) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/v1/models", method: .get, headers: [.authorization: "Bearer \(key)"]) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/k/\(key)/v1/models", method: .get) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/k/wrong/v1/models", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            try await c.execute(uri: "/v1/models", method: .get, headers: [.authorization: "Bearer wrong"]) { XCTAssertEqual($0.status, .unauthorized) }
            try await c.execute(uri: "/v1/models", method: .get, headers: [HTTPField.Name("x-api-key")!: key]) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/v1/models", method: .get, headers: [HTTPField.Name("x-api-key")!: "wrong"]) { XCTAssertEqual($0.status, .unauthorized) }
            // Bare-host paths (no /v1) take the same keys.
            try await c.execute(uri: "/models", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            try await c.execute(uri: "/models", method: .get, headers: [HTTPField.Name("x-api-key")!: key]) { XCTAssertEqual($0.status, .ok) }
            try await c.execute(uri: "/k/\(key)/models", method: .get) { XCTAssertEqual($0.status, .ok) }
        }
    }

    /// A client given only the host reaches every protocol whether or not it adds /v1.
    func testEveryAPIRouteAnswersWithAndWithoutV1() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { c in
            for path in ["/models", "/v1/models"] {
                try await c.execute(uri: path, method: .get) { XCTAssertEqual($0.status, .ok, path) }
            }
            // No chat model is downloaded here, so these reach their handlers and fail model resolution, not routing.
            for path in ["/chat/completions", "/v1/chat/completions", "/completions", "/v1/completions",
                         "/responses", "/v1/responses", "/messages", "/v1/messages"] {
                try await c.execute(uri: path, method: .post, headers: [.contentType: "application/json"],
                                    body: ByteBuffer(string: #"{"model":"qwen3.5-0.8b","max_tokens":5,"prompt":"hi","input":"hi","messages":[{"role":"user","content":"hi"}]}"#)) {
                    XCTAssertNotEqual($0.status, .notFound, path)
                    let o = try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as? [String: Any]
                    XCTAssertNotNil((o?["error"] as? [String: Any])?["message"], path)
                }
            }
        }
    }

    func testCompletionsRejectsUnsupportedShapes() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { c in
            for body in [#"{"prompt":["a","b"]}"#, #"{"prompt":""}"#, #"{"prompt":"a","n":2}"#, #"{"prompt":"a","suffix":"z"}"#] {
                try await c.execute(uri: "/v1/completions", method: .post, headers: [.contentType: "application/json"],
                                    body: ByteBuffer(string: body)) { XCTAssertEqual($0.status, .badRequest, body) }
            }
        }
    }

    func testStopSequencesCutAcrossChunks() async throws {
        let (source, feed) = AsyncThrowingStream.makeStream(of: ChatEvent.self)
        for s in ["1, 2, 3", ", 4, ", "5, 6"] { feed.yield(.delta(s)) }
        feed.yield(.done(finishReason: "length", usage: ChatUsage(promptTokens: 9, completionTokens: 3)))
        feed.finish()
        var text = "", finish = ""
        for try await e in applyStops(source, ["5"]) {
            if case .delta(let s) = e { text += s }
            if case .done(let f, _) = e { finish = f }
        }
        XCTAssertEqual(text, "1, 2, 3, 4, ")
        XCTAssertEqual(finish, "stop")
        XCTAssertEqual(stopSequences(.string("x")), ["x"])
        XCTAssertEqual(stopSequences(.array([.string("a"), .string("b")])), ["a", "b"])
    }
}
