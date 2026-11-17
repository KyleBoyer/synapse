import Foundation
import Hummingbird
import XCTest
@testable import SynapseCore

final class VideoInputTests: XCTestCase {
    private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    private func assertBadRequest(_ body: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("expected 400", file: file, line: line) } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .badRequest, "\(error)", file: file, line: line)
        }
    }

    func testVideoPartsParse() throws {
        let v = try json(#"""
        [{"type":"text","text":"what"},
         {"type":"video_url","video_url":{"url":"data:video/mp4;base64,AAAA"}},
         {"type":"input_video","video_url":"https://x/a.mp4"}]
        """#)
        XCTAssertEqual(try ChatParse.parts(v), [.text("what"), .video("data:video/mp4;base64,AAAA"), .video("https://x/a.mp4")])
    }

    func testLoadVideoAcceptsMP4DataURL() async throws {
        let data = try Data(contentsOf: TestSupport.fixture("zebra.mp4"))
        let file = try await MediaFiles.loadVideo("data:video/mp4;base64," + data.base64EncodedString())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    /// Reading a client-named local file would let any API client read files on this Mac.
    func testLoadVideoRefusesLocalPathsAndNonVideo() async throws {
        let fixture = TestSupport.fixture("zebra.mp4")
        await assertBadRequest { try await MediaFiles.loadVideo(fixture.absoluteString) }
        await assertBadRequest { try await MediaFiles.loadVideo(fixture.path) }
        await assertBadRequest { try await MediaFiles.loadVideo("data:image/png;base64,AAAA") }
        // Right mime, but not a video: no track for AVFoundation to read.
        await assertBadRequest { try await MediaFiles.loadVideo("data:video/mp4;base64," + Data("not a video".utf8).base64EncodedString()) }
    }

    func testModelWithoutVideoProcessorIsRefused() async throws {
        let store = try TestSupport.store(downloaded: ["qwen3.5-0.8b"])
        let chat = ChatService(store: store)
        let spec = try XCTUnwrap(Catalog.spec("qwen3.5-0.8b"))
        let video = [ChatMessage(role: .user, text: "hi", videos: [TestSupport.fixture("zebra.mp4")])]
        await assertBadRequest { try await requireMediaSupport(chat, spec, video) }
        // Text-only requests are unaffected, and the processor file is what turns video on.
        try await requireMediaSupport(chat, spec, [ChatMessage(role: .user, text: "hi")])
        let maybeFolder = await store.folder(for: "qwen3.5-0.8b")
        let folder = try XCTUnwrap(maybeFolder)
        try Data("{}".utf8).write(to: folder.appending(path: "video_preprocessor_config.json"))
        try await requireMediaSupport(chat, spec, video)
    }
}
