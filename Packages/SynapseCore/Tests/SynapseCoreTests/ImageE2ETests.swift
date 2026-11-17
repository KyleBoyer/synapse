import Foundation
import Hummingbird
import HummingbirdTesting
import ImageIO
import NIOCore
import XCTest
@testable import SynapseCore

/// Real weights through the Images API. Set SYNAPSE_IMAGE_E2E_IDS and SYNAPSE_MODELS_DIR.
final class ImageE2ETests: XCTestCase, @unchecked Sendable {
    func testFluxGenerationAndEdit() async throws { try await check("flux2-klein-4b", edit: true) }
    /// On Macs under 48 GB this runs with the 4-bit encoder and transformer (Flux2ImageEngine).
    func testFlux9BGenerationAndEdit() async throws { try await check("flux2-klein-9b", edit: true) }
    func testZImageGeneration() async throws { try await check("z-image-turbo") }
    func testQwenImageGeneration() async throws { try await check("qwen-image-2.1-q4") }

    private func check(_ id: String, edit: Bool = false) async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SYNAPSE_IMAGE_E2E_IDS"]?.split(separator: ",").contains(Substring(id)) == true else {
            throw XCTSkip("Include \(id) in SYNAPSE_IMAGE_E2E_IDS")
        }
        let root = env["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let output = URL(fileURLWithPath: env["SYNAPSE_IMAGE_OUTPUT_DIR"] ?? NSTemporaryDirectory() + "synapse-image-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = ModelStore(root: root)
        let manager = ModelManager()
        let service = ImageService(store: store, models: manager, engineFactory: ImageEngines.real)
        _ = try await service.resolve(id, edit: edit)
        let settings = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: settings)
        let app = Application(router: buildRouter(queue: queue, store: store, settings: settings, images: service))
        do {
            try await app.test(.router) { client in
                let body = try JSONSerialization.data(withJSONObject: [
                    "model": id, "prompt": "A red ceramic teapot on a wooden table, daylight, photograph.",
                    "size": "256x256", "seed": 42,
                ])
                let generated = try await client.execute(uri: "/v1/images/generations", method: .post,
                                                        headers: [.contentType: "application/json"], body: ByteBuffer(data: body))
                let png = try self.image(generated)
                try png.write(to: output.appending(path: "\(id).png"))
                if edit {
                    let boundary = "SynapseImageCheck"
                    var data = Data()
                    for (name, value) in [("model", id), ("prompt", "Make the teapot blue. Keep the wooden table."), ("size", "256x256"), ("seed", "43")] {
                        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
                    }
                    data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"source.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
                    data.append(png)
                    data.append(Data("\r\n--\(boundary)--\r\n".utf8))
                    let edited = try await client.execute(uri: "/v1/images/edits", method: .post,
                        headers: [.contentType: "multipart/form-data; boundary=\(boundary)"], body: ByteBuffer(data: data))
                    let result = try self.image(edited)
                    XCTAssertNotEqual(result, png)
                    try result.write(to: output.appending(path: "\(id)-edit.png"))
                }
            }
        } catch {
            await manager.unloadAllIdle()
            throw error
        }
        await manager.unloadAllIdle()
        print("[image \(id)] PNGs saved in \(output.path)")
    }

    private func image(_ response: TestResponse) throws -> Data {
        XCTAssertEqual(response.status, .ok, String(buffer: response.body))
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
        let items = try XCTUnwrap(json?["data"] as? [[String: Any]])
        let encoded = try XCTUnwrap(items.first?["b64_json"] as? String)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
        let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16, "Image is blank or nearly uniform")
        return data
    }
}
