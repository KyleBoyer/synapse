import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

private func object(_ r: TestResponse) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any])
}

private func body(_ o: [String: Any]) -> ByteBuffer { ByteBuffer(data: try! JSONSerialization.data(withJSONObject: o)) }

final class VideoAPITests: XCTestCase {
    private func app() throws -> (some ApplicationProtocol, VideoService) {
        let store = try TestSupport.store(downloaded: ["parakeet-v3", "ltx-2.3-distilled"])
        let videos = VideoService(store: store, models: ModelManager(), engineFactory: { _, _ in MockVideoEngine() })
        let router = buildRouter(queue: JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: SettingsBox(Settings())),
                                 store: store, settings: SettingsBox(Settings()), videos: videos)
        return (Application(router: router), videos)
    }


    func testCreatePollDownloadListDelete() async throws {
        let (app, _) = try app()
        try await app.test(.router) { c in
            var id = ""
            try await c.execute(uri: "/v1/videos", method: .post, headers: [.contentType: "application/json"],
                                body: body(["model": "sora-2", "prompt": "a fox in snow", "seconds": "4", "size": "256x256"])) { r in
                XCTAssertEqual(r.status, .ok)
                let o = try object(r)
                id = o["id"] as? String ?? ""
                XCTAssertTrue(id.hasPrefix("video_"))
                XCTAssertEqual(o["object"] as? String, "video")
                XCTAssertEqual(o["model"] as? String, "ltx-2.3-distilled")
                XCTAssertEqual(o["seconds"] as? String, "4")
                XCTAssertEqual(o["size"] as? String, "256x256")
                XCTAssertTrue(["queued", "in_progress"].contains(o["status"] as? String ?? ""))
            }
            try await c.execute(uri: "/v1/videos/\(id)/content", method: .get) { r in XCTAssertEqual(r.status, .notFound) }
            var status = ""
            for _ in 0..<200 where status != "completed" && status != "failed" {
                try await Task.sleep(for: .milliseconds(50))
                try await c.execute(uri: "/v1/videos/\(id)", method: .get) { r in
                    let o = try object(r)
                    status = o["status"] as? String ?? ""
                    if status == "completed" {
                        XCTAssertEqual(o["progress"] as? Int, 100)
                        XCTAssertNotNil(o["completed_at"] as? Int)
                        XCTAssertNotNil(o["expires_at"] as? Int)
                    }
                }
            }
            XCTAssertEqual(status, "completed")
            try await c.execute(uri: "/v1/videos/\(id)/content", method: .get) { r in
                XCTAssertEqual(r.headers[.contentType], "video/mp4")
                XCTAssertEqual(String(decoding: Data(buffer: r.body)[4..<8], as: UTF8.self), "ftyp")
            }
            try await c.execute(uri: "/v1/videos/\(id)/content?variant=thumbnail", method: .get) { r in
                XCTAssertEqual(Array(Data(buffer: r.body).prefix(2)), [0xFF, 0xD8])
            }
            try await c.execute(uri: "/v1/videos", method: .get) { r in
                let o = try object(r)
                XCTAssertEqual(o["object"] as? String, "list")
                XCTAssertEqual((o["data"] as? [[String: Any]])?.first?["id"] as? String, id)
            }
            try await c.execute(uri: "/v1/videos/\(id)", method: .delete) { r in
                XCTAssertEqual(try object(r)["deleted"] as? Bool, true)
            }
            try await c.execute(uri: "/v1/videos/\(id)", method: .get) { r in XCTAssertEqual(r.status, .notFound) }
        }
    }

    func testBadRequests() async throws {
        let (app, _) = try app()
        try await app.test(.router) { c in
            for bad: [String: Any] in [["prompt": "x", "seconds": "5"], ["prompt": "x", "size": "100x100"], ["seconds": "4"],
                                       ["prompt": "x", "model": "qwen3.5-0.8b"]] {
                try await c.execute(uri: "/v1/videos", method: .post, headers: [.contentType: "application/json"], body: body(bad)) { r in
                    XCTAssertEqual(r.status, .badRequest, "\(bad)")
                }
            }
            try await c.execute(uri: "/v1/videos/video_nope", method: .get) { r in XCTAssertEqual(r.status, .notFound) }
            try await c.execute(uri: "/v1/videos/video_nope/remix", method: .post) { r in XCTAssertEqual(r.status, .badRequest) }
        }
    }

    /// Real mlx-video output lines (Rich, forced to a pipe): two denoising stages map to one 0...1 run.
    func testLTXProgressAcrossStages() {
        let p = LTXProgress()
        XCTAssertNil(p.feed("Loading transformer..."))
        XCTAssertEqual(p.feed("\u{1B}[36mDenoising (distilled)\u{1B}[0m ━━━━━╺━━━━━━━━  50%"), 0.25)
        XCTAssertEqual(p.feed("Denoising (distilled) ━━━━━━━━━━━━━━━━ 100%"), 0.5)
        XCTAssertEqual(p.feed("Denoising (stage 2) ━━━━━━━━━━━━━━━━   0%"), 0.5)
        XCTAssertEqual(p.feed("Denoising (stage 2) ━━━━━━━━━━━━━━━━ 100%"), 1)
    }

    func testLTXDownloadSkipsDuplicateShardsAndBorrowsOnlyTheEncoder() throws {
        let tree = #"[{"type":"file","path":"transformer/model-00001-of-00018.safetensors"},{"type":"file","path":"transformer/model-00001-of-00008.safetensors"},{"type":"file","path":"text_encoder/config.json"},{"type":"file","path":"text_encoder/model-00001-of-00005.safetensors"},{"type":"file","path":"vae/decoder/model.safetensors"}]"#
        let main = try HFDownloader.snapshotFiles(Data(tree.utf8), exclude: VideoEngines.ltxUnused).map(\.path)
        XCTAssertFalse(main.contains("transformer/model-00001-of-00008.safetensors"))
        XCTAssertTrue(main.contains("transformer/model-00001-of-00018.safetensors"))
        let borrowed = try HFDownloader.snapshotFiles(Data(tree.utf8), only: ["text_encoder/", "tokenizer/"]).map(\.path)
        XCTAssertEqual(Set(borrowed), ["text_encoder/config.json", "text_encoder/model-00001-of-00005.safetensors"])
    }
}

final class ModelReserveTests: XCTestCase {
    /// An external process's memory counts while it runs and is gone afterwards, success or failure.
    func testReserveCountsOnlyDuringTheRun() async throws {
        let m = ModelManager(config: .init(budgetBytes: 1 << 40))
        let during = try await m.reserve("video", estimatedBytes: 1000) { await m.residentBytes }
        XCTAssertEqual(during, 1000)
        let after = await m.residentBytes
        XCTAssertEqual(after, 0)
        do {
            try await m.reserve("video", estimatedBytes: 1000) { throw CancellationError() }
            XCTFail("expected the error to propagate")
        } catch is CancellationError {}
        let afterFailure = await m.residentBytes
        XCTAssertEqual(afterFailure, 0)
    }
}
