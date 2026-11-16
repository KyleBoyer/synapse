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
