import CoreImage
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// `/v1/images/cutout` runs macOS Vision for real (built in, nothing to download); `/v1/images/depth` needs a model.
final class ImageToolsTests: XCTestCase, @unchecked Sendable {
    private func app(downloaded: [String] = []) throws -> some ApplicationProtocol {
        let store = try TestSupport.store(downloaded: downloaded)
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box,
                             engineFactory: { _, _ in FakeEngine() })
        return Application(router: buildRouter(queue: queue, store: store, settings: box))
    }

    private func form(_ image: Data, _ fields: [String: String] = [:]) -> ByteBuffer {
        var body = ByteBuffer()
        for (k, v) in fields { body.writeString("--XyZ\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n") }
        body.writeString("--XyZ\r\nContent-Disposition: form-data; name=\"image\"; filename=\"a.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
        body.writeBytes(image)
        body.writeString("\r\n--XyZ--\r\n")
        return body
    }

    /// The zebra cut out keeps its size, gains transparency around it, and the mask is mostly black with a white subject.
    func testCutoutAndMaskOfTheZebra() async throws {
        let zebra = try Data(contentsOf: TestSupport.fixture("zebra.jpg"))
        let source = try XCTUnwrap(CIImage(data: zebra)).extent.size
        try await app().test(.router) { c in
            for output in ["cutout", "mask"] {
                try await c.execute(uri: "/v1/images/cutout", method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                                    body: self.form(zebra, ["output": output])) { r in
                    XCTAssertEqual(r.status, .ok, String(buffer: r.body))
                    let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any])
                    let b64 = ((o["data"] as? [[String: Any]])?.first?["b64_json"] as? String) ?? ""
                    let png = try XCTUnwrap(Data(base64Encoded: b64))
                    let img = try XCTUnwrap(CIImage(data: png))
                    XCTAssertEqual(img.extent.size, source, output)
                    XCTAssertEqual(o["background"] as? String, output == "cutout" ? "transparent" : "opaque")
                    // Average alpha (cutout) or brightness (mask) is between empty and full: a subject was found.
                    let avg = CIContext().averageRGBA(img)
                    let coverage = output == "cutout" ? avg[3] : avg[0]
                    print(String(format: "[cutout] %@: coverage %.2f", output, coverage))
                    XCTAssertGreaterThan(coverage, 0.05, output)
                    XCTAssertLessThan(coverage, 0.95, output)
                }
            }
            try await c.execute(uri: "/v1/images/cutout", method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                                body: self.form(zebra, ["output": "outline"])) { r in XCTAssertEqual(r.status, .badRequest) }
            try await c.execute(uri: "/v1/images/depth", method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                                body: self.form(zebra)) { r in XCTAssertEqual(r.status, .serviceUnavailable) }
        }
    }
}

/// Depth Anything V2 through Core ML. SYNAPSE_E2E=1 with depth-anything-v2-small downloaded.
final class ImageToolsE2ETests: XCTestCase {
    /// The zebra (Vision's subject mask) is nearer than the sky and field behind it: brighter in the depth map.
    func testDepthPutsTheZebraInFront() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        guard await store.downloaded.contains("depth-anything-v2-small") else { throw XCTSkip("depth-anything-v2-small not downloaded") }
        let images = ImageService(store: store, models: ModelManager(), engineFactory: ImageEngines.real)
        let zebra = try Data(contentsOf: TestSupport.fixture("zebra.jpg"))
        let start = Date()
        let (spec, png) = try await images.depth(zebra, model: nil)
        let took = Date().timeIntervalSince(start)
        let warm = Date()
        _ = try await images.depth(zebra, model: nil)
        let maskPNG = try await images.cutout(zebra, output: .mask)
        let depth = try XCTUnwrap(CIImage(data: png)), mask = try XCTUnwrap(CIImage(data: maskPNG))
        XCTAssertEqual(depth.extent.size, mask.extent.size)
        // Mean depth inside the mask and outside it.
        let ctx = CIContext()
        let inside = depth.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        let outside = depth.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask.applyingFilter("CIColorInvert")])
        let m = ctx.averageRGBA(mask)[0]
        let near = ctx.averageRGBA(inside)[0] / max(m, 1e-3), far = ctx.averageRGBA(outside)[0] / max(1 - m, 1e-3)
        print(String(format: "[depth] %@: %.2f s cold, %.2f s warm; subject %.2f, background %.2f", spec.id, took,
                     Date().timeIntervalSince(warm), near, far))
        if let dir = ProcessInfo.processInfo.environment["SYNAPSE_SCRATCH"] { try png.write(to: URL(fileURLWithPath: dir).appending(path: "zebra-depth.png")) }
        XCTAssertGreaterThan(near, far + 0.2)
    }
}

extension CIContext {
    /// Mean of each channel, 0...1.
    func averageRGBA(_ image: CIImage) -> [Float] {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return px.map { Float($0) / 255 }
    }
}
