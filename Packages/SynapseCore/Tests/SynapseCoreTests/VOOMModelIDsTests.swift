import Foundation
import XCTest
@testable import SynapseCore

final class VOOMModelIDsTests: XCTestCase {
    func testListsCheckoutModelsAndPageableImageModels() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "voom-ids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        func write(_ path: String, _ body: String) throws {
            let url = tmp.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        try write("checkout/models/Qwen3.5-9B/config.json", "{}")
        try write("checkout/models/no-config/README", "")
        try write("models/mlx/org/Z-Image-Turbo-bf16/model_index.json", #"{"_class_name":"ZImagePipeline"}"#)
        try write("models/mlx/org/FLUX.2-klein-4B/model_index.json", #"{"_class_name":"Flux2KleinPipeline"}"#)

        let ids = VOOMRuntime.modelIDs(checkout: tmp.appending(path: "checkout").path, modelsRoot: tmp.appending(path: "models"))
        XCTAssertEqual(ids, ["voom:Qwen3.5-9B", "voom:Z-Image-Turbo-bf16"])
        XCTAssertEqual(VOOMRuntime.modelIDs(checkout: tmp.appending(path: "checkout").path), ["voom:Qwen3.5-9B"])
    }
}
