import Foundation
import XCTest
@testable import SynapseCore

final class ModelPrepTests: XCTestCase {
    func testStepsDependOnModelAndMemory() throws {
        let minicpm = try XCTUnwrap(Catalog.spec("minicpm-o-4.5")), qwen = try XCTUnwrap(Catalog.spec("qwen3-omni-30b"))
        let gemma = try XCTUnwrap(Catalog.spec("gemma-3n-e2b"))
        XCTAssertEqual(ModelPrep.step(for: minicpm, physicalMemory: 16 << 30), .quantize4)
        XCTAssertEqual(ModelPrep.steps(for: qwen, physicalMemory: 16 << 30), [.quantize4, .offloadExperts])
        XCTAssertEqual(ModelPrep.steps(for: qwen, physicalMemory: 64 << 30), [.quantize4])
        XCTAssertEqual(ModelPrep.steps(for: qwen, physicalMemory: 128 << 30), [], "the bf16 runs as downloaded")
        XCTAssertNil(ModelPrep.step(for: gemma, physicalMemory: 16 << 30))
        XCTAssertNil(ModelPrep.step(for: minicpm, physicalMemory: 128 << 30), "a Mac Studio runs the original")
    }

    /// Inkling 2 Mini: under 32 GB the IQ4_NL is fetched with its imatrix and requantized; larger Macs run a published file.
    func testInklingIsRequantizedOnlyWhereThePublishedFilesDoNotFit() throws {
        let small = Catalog.inkling2Mini(physicalMemory: 16 << 30)
        XCTAssertEqual(small.files, ["Inkling-2-Mini-IQ4_NL.gguf", ModelPrep.imatrix, "mmproj-Inkling-2-Mini-Q8_0.gguf"])
        XCTAssertEqual(ModelPrep.steps(for: small, physicalMemory: 16 << 30), [.requantizeGGUF])
        XCTAssertEqual(ModelPrep.steps(for: small, physicalMemory: 32 << 30), [])
        XCTAssertEqual(Catalog.inkling2Mini(physicalMemory: 32 << 30).files, ["Inkling-2-Mini-IQ4_NL.gguf", "mmproj-Inkling-2-Mini-Q8_0.gguf"])
        XCTAssertEqual(Catalog.inkling2Mini(physicalMemory: 64 << 30).files?.first, "Inkling-2-Mini-Q8_0.gguf")
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: ModelPrep.imatrix))
        XCTAssertFalse(ModelPrep.isDone(.requantizeGGUF, dir), "the imatrix is deleted once the weights are requantized")
    }

    func testPreparedFolderIsLeftAlone() async throws {
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appending(path: ModelPrep.marker))
        // Already prepared: returns at once, without installing a runtime or touching the folder.
        try await ModelPrep.prepareIfNeeded(try XCTUnwrap(Catalog.spec("minicpm-o-4.5")), folder: dir, physicalMemory: 16 << 30)
        XCTAssertTrue(ModelPrep.isPrepared(dir))
    }

    func testStepsAlreadyInTheFolderAreRecognized() throws {
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type": "x"}"#.utf8).write(to: dir.appending(path: "config.json"))
        XCTAssertFalse(ModelPrep.isDone(.quantize4, dir))
        try Data(#"{"model_type": "x", "quantization": {"bits": 4}}"#.utf8).write(to: dir.appending(path: "config.json"))
        XCTAssertTrue(ModelPrep.isDone(.quantize4, dir))
        XCTAssertFalse(ModelPrep.isDone(.offloadExperts, dir))
        try Data("{}".utf8).write(to: dir.appending(path: "offload_index.json"))
        XCTAssertTrue(ModelPrep.isDone(.offloadExperts, dir))
    }
}
