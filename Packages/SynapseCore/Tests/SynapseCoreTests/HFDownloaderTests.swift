import Synchronization
import NIOCore
import HummingbirdTesting
import Hummingbird
import XCTest
@testable import SynapseCore

final class HFDownloaderTests: XCTestCase {
    private func listing(_ paths: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: paths.map { ["type": "file", "path": $0, "size": 10] })
    }

    func testChatDiffusersAndMfluxSnapshots() throws {
        for paths in [
            ["config.json", "model.safetensors"],
            ["model_index.json", "transformer/config.json", "transformer/diffusion_pytorch_model.safetensors", "tokenizer/tokenizer.json"],
            ["transformer/0.safetensors", "text_encoder/0.safetensors", "vae/0.safetensors", "processor/tokenizer.json"],
        ] {
            XCTAssertEqual(try HFDownloader.snapshotFiles(listing(paths)).map(\.path), paths)
        }
    }

    func testRejectsEmptySnapshotsAndUnsafePaths() throws {
        XCTAssertThrowsError(try HFDownloader.snapshotFiles(listing(["config.json", "README.md"])))
        for path in ["../outside.safetensors", "/outside.safetensors", "a/../../outside.safetensors", "a//b.safetensors", "a\\b.safetensors"] {
            XCTAssertThrowsError(try HFDownloader.snapshotFiles(listing([path])), path)
        }
    }

    func testExcludesDuplicateWeightsAndUnneededFiles() throws {
        let data = try listing(["flux-2-klein-4b.safetensors", "transformer/model.safetensors", "tokenizer/tokenizer.json", "README.md", "example.png"])
        XCTAssertEqual(try HFDownloader.snapshotFiles(data, exclude: ["flux-2-klein-4b.safetensors"]).map(\.path),
                       ["transformer/model.safetensors", "tokenizer/tokenizer.json"])
    }
}

final class HFDownloaderFetchTests: XCTestCase {
    private static let content = Data((0..<3_000_000).map { UInt8($0 % 251) })

    /// Serves `content` at /file (honoring Range unless `ignoreRange`), and 401 at /gated.
    private func withServer(ignoreRange: Bool = false, _ body: @escaping @Sendable (URL) async throws -> Void) async throws {
        let router = Router()
        let content = Self.content
        router.get("file") { req, _ -> Response in
            if !ignoreRange, let range = req.headers[.range], let from = Int(range.dropFirst("bytes=".count).dropLast()) {
                return Response(status: .partialContent, body: .init(byteBuffer: ByteBuffer(data: content.subdata(in: from..<content.count))))
            }
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: content)))
        }
        router.get("gated") { _, _ -> Response in Response(status: .unauthorized) }
        try await Application(router: router).test(.live) { client in
            try await body(URL(string: "http://localhost:\(try XCTUnwrap(client.port))")!)
        }
    }

    private func dst() throws -> URL {
        let dir = try TestSupport.tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appending(path: "model.safetensors")
    }

    func testFreshDownloadWritesTheFileAndReportsBytes() async throws {
        let file = try dst()
        let last = Mutex<Int64>(0)
        try await withServer { base in
            try await HFDownloader.fetch(base.appending(path: "file"), to: file, token: nil) { n in last.withLock { $0 = n } }
        }
        XCTAssertEqual(try Data(contentsOf: file), Self.content)
        XCTAssertEqual(last.withLock { $0 }, Int64(Self.content.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".partial"))
    }

    func testResumesAPartialAndStartsOverWhenRangeIsIgnored() async throws {
        for ignore in [false, true] {
            let file = try dst()
            try Self.content.prefix(1_000_000).write(to: file.appendingPathExtension("partial"))
            try await withServer(ignoreRange: ignore) { base in
                try await HFDownloader.fetch(base.appending(path: "file"), to: file, token: nil) { _ in }
            }
            XCTAssertEqual(try Data(contentsOf: file), Self.content, "ignoreRange: \(ignore)")
        }
    }

    func testRefusalSaysGated() async throws {
        let file = try dst()
        try await withServer { base in
            do {
                try await HFDownloader.fetch(base.appending(path: "gated"), to: file, token: nil) { _ in }
                XCTFail("expected a refusal")
            } catch { XCTAssertTrue(error.localizedDescription.contains("gated"), error.localizedDescription) }
        }
    }
}
