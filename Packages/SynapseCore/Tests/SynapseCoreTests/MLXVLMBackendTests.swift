import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Synchronization
import XCTest
@testable import SynapseCore

final class MLXVLMBackendTests: XCTestCase {
    func testRequestBodyUsesOpenAIPartShapes() throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        try Data("RIFFfake".utf8).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2])
        let body = try MLXVLMChat.body([ChatMessage(role: .system, text: "Be brief."),
                                        ChatMessage(role: .user, text: "What is said?", images: [png], videos: [URL(fileURLWithPath: "/tmp/v.mp4")], audios: [wav])],
                                       options: ChatOptions(maxTokens: 9, temperature: 0), model: "/models/gemma")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o["model"] as? String, "/models/gemma")
        XCTAssertEqual(o["stream"] as? Bool, true)
        XCTAssertEqual(o["max_tokens"] as? Int, 9)
        let parts = try XCTUnwrap(((o["messages"] as? [[String: Any]])?[1])?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url", "input_audio", "video_url"])
        let image = (parts[1]["image_url"] as? [String: Any])?["url"] as? String ?? ""
        XCTAssertTrue(image.hasPrefix("data:image/png;base64,"), image)
        let audio = try XCTUnwrap(parts[2]["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertEqual(Data(base64Encoded: audio["data"] as? String ?? ""), Data("RIFFfake".utf8))
        XCTAssertEqual((parts[3]["video_url"] as? [String: Any])?["url"] as? String, "/tmp/v.mp4")
    }

    /// A stub that answers like mlx-vlm: content chunks, a finish chunk, a usage chunk, then [DONE].
    func testStreamMapsDeltasFinishAndUsage() async throws {
        let router = Router()
        router.post("v1/chat/completions") { _, _ -> Response in
            let lines = [#"{"choices":[{"index":0,"delta":{"role":"assistant","content":"The "}}]}"#,
                         #"{"choices":[{"index":0,"delta":{"content":"fox."}}]}"#,
                         #"{"choices":[{"index":0,"delta":{"content":"<|tts_eos|>"}}]}"#,
                         #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
                         #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14}}"#]
            let text = lines.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(byteBuffer: ByteBuffer(string: text)))
        }
        try await Application(router: router).test(.live) { client in
            let port = try XCTUnwrap(client.port)
            let finished = Mutex(false)
            var events: [ChatEvent] = []
            for try await e in MLXVLMChat.stream(base: URL(string: "http://localhost:\(port)")!, body: Data("{}".utf8),
                                                 onFinish: { finished.withLock { $0 = true } }) {
                events.append(e)
            }
            // The lease and GPU gate are released when the stream ends.
            for _ in 0..<50 where !finished.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(finished.withLock { $0 })
            XCTAssertEqual(events, [.delta("The "), .delta("fox."),
                                    .done(finishReason: "length", usage: ChatUsage(promptTokens: 12, completionTokens: 2))])
        }
    }

    /// mlx-vlm reports failures mid-stream as a data line; they must reach the client, not end as an empty answer.
    func testStreamErrorIsRaised() async throws {
        let router = Router()
        router.post("v1/chat/completions") { _, _ -> Response in
            let text = #"data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}"# + "\n\n"
                + #"data: {"error": "[METAL] Command buffer execution failed: Insufficient Memory"}"# + "\n\n"
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(byteBuffer: ByteBuffer(string: text)))
        }
        try await Application(router: router).test(.live) { client in
            let port = try XCTUnwrap(client.port)
            do {
                for try await _ in MLXVLMChat.stream(base: URL(string: "http://localhost:\(port)")!, body: Data("{}".utf8), onFinish: {}) {}
                XCTFail("expected the stream to throw")
            } catch {
                XCTAssertTrue("\(error)".contains("Insufficient Memory"), "\(error)")
            }
        }
    }

    func testAudioPartsParseAndRefuseNonOmniModels() async throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"type":"input_audio","input_audio":{"data":"UklGRg==","format":"wav"}}]"#.utf8))
        XCTAssertEqual(try ChatParse.parts(v), [.audio(data: "UklGRg==", format: "wav")])
        let chat = ChatService(store: try TestSupport.store(downloaded: ["qwen3.5-0.8b"]))
        let qwen = try XCTUnwrap(Catalog.spec("qwen3.5-0.8b")), gemma = try XCTUnwrap(Catalog.spec("gemma-3n-e2b"))
        let msg = [ChatMessage(role: .user, text: "hi", audios: [URL(fileURLWithPath: "/tmp/a.wav")])]
        do { try await requireMediaSupport(chat, qwen, msg); XCTFail("expected 400") } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .badRequest)
        }
        try await requireMediaSupport(chat, gemma, msg)
    }
}

final class AudioInputFileTests: XCTestCase {
    /// Two mp3/m4a clips must decode to two different WAVs (the decoder names every output audio.wav).
    func testNonWAVClipsDecodeToSeparateFiles() async throws {
        let decoder = AudioDecoder(ffmpegURL: try TestSupport.ffmpeg())
        let m4a = try Data(contentsOf: TestSupport.fixture("en.m4a")).base64EncodedString()
        let a = try await MediaFiles.loadAudio(base64: m4a, format: "m4a", decoder: decoder)
        let b = try await MediaFiles.loadAudio(base64: m4a, format: "m4a", decoder: decoder)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.pathExtension, "wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }
}

final class HFTokenTests: XCTestCase {
    func testCLITokenComesFromEnvThenTokenFile() throws {
        let home = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(HFDownloader.cliToken(environment: [:], home: home))
        try FileManager.default.createDirectory(at: home.appending(path: ".cache/huggingface"), withIntermediateDirectories: true)
        try "hf_file\n".write(to: home.appending(path: ".cache/huggingface/token"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HFDownloader.cliToken(environment: [:], home: home), "hf_file")
        XCTAssertEqual(HFDownloader.cliToken(environment: ["HF_TOKEN": "hf_env"], home: home), "hf_env")
    }
}
