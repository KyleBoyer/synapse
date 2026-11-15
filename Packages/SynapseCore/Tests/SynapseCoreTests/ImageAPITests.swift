import CoreGraphics
import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import ImageIO
import NIOCore
import UniformTypeIdentifiers
import XCTest
@testable import SynapseCore

final class UnsafeBox: @unchecked Sendable { var value = "" }

actor FakeImageEngine: ImageEngine {
    func generate(_ request: ImageRequest, progress: @escaping @Sendable (ImageProgress) -> Void) async throws -> Data {
        let png = ImageAPITests.png(request.width, request.height)
        for s in 1...4 { progress(ImageProgress(step: s, totalSteps: 4, preview: ImageAPITests.png(16, 16))) }
        return png
    }
}

final class ImageAPITests: XCTestCase, @unchecked Sendable {
    static func png(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
        return out as Data
    }

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private func makeApp(downloaded: [String] = ["z-image-turbo", "flux2-klein-4b"]) throws -> Application<RouterResponder<SynapseContext>> {
        let store = try TestSupport.store(downloaded: downloaded)
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box,
                             engineFactory: { _, _ in FakeEngine() })
        let images = ImageService(store: store, models: ModelManager(), engineFactory: { _, _ in FakeImageEngine() })
        return Application(router: buildRouter(queue: queue, store: store, settings: box, images: images))
    }

    private func post(_ c: some TestClientProtocol, _ body: String, uri: String = "/v1/images/generations",
                      check: @escaping @Sendable (TestResponse) throws -> Void) async throws {
        try await c.execute(uri: uri, method: .post, headers: [.contentType: "application/json", HTTPField.Name("Host")!: "example.test:1234"],
                            body: ByteBuffer(string: body)) { try check($0) }
    }

    private func decode(_ r: TestResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as! [String: Any]
    }

    func testGenerationsB64() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"prompt":"a cat","size":"512x256","model":"gpt-image-1"}"#) { r in
                XCTAssertEqual(r.status, .ok)
                let j = try self.decode(r)
                XCTAssertEqual(j["size"] as? String, "512x256")
                XCTAssertEqual(j["output_format"] as? String, "png")
                XCTAssertEqual(j["background"] as? String, "opaque")
                XCTAssertNotNil(j["usage"])
                let d = Data(base64Encoded: ((j["data"] as! [[String: Any]])[0]["b64_json"] as! String))!
                let s = Self.pixelSize(d)
                XCTAssertEqual(s?.0, 512); XCTAssertEqual(s?.1, 256)
            }
        }
    }

    func testJpegOutput() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"prompt":"x","size":"256x256","output_format":"jpeg","output_compression":50}"#) { r in
                let d = Data(base64Encoded: ((try self.decode(r)["data"] as! [[String: Any]])[0]["b64_json"] as! String))!
                XCTAssertEqual(Array(d.prefix(3)), [0xFF, 0xD8, 0xFF])
            }
        }
    }

    func testURLModeAndFetch() async throws {
        try await makeApp().test(.router) { c in
            let box = UnsafeBox()
            try await self.post(c, #"{"prompt":"x","size":"256x256","response_format":"url"}"#) { r in
                box.value = ((try self.decode(r)["data"] as! [[String: Any]])[0]["url"] as! String)
            }
            let url = box.value
            XCTAssertTrue(url.hasPrefix("http://example.test:1234/v1/images/files/"), url)
            XCTAssertTrue(url.hasSuffix(".png"))
            let path = String(url.dropFirst("http://example.test:1234".count))
            try await c.execute(uri: path, method: .get) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(r.headers[.contentType], "image/png")
                XCTAssertEqual(Self.pixelSize(Data(buffer: r.body))?.0, 256)
            }
            try await c.execute(uri: "/v1/images/files/nope.png", method: .get) { XCTAssertEqual($0.status, .notFound) }
        }
    }

    private func events(_ r: TestResponse) -> [(String, [String: Any])] {
        String(buffer: r.body).components(separatedBy: "\n\n").compactMap { frame in
            let lines = frame.split(separator: "\n").map(String.init)
            guard let e = lines.first(where: { $0.hasPrefix("event: ") }), let d = lines.first(where: { $0.hasPrefix("data: ") }),
                  let obj = try? JSONSerialization.jsonObject(with: Data(d.dropFirst(6).utf8)) as? [String: Any] else { return nil }
            return (String(e.dropFirst(7)), obj)
        }
    }

    func testStreamPartialImages() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"prompt":"x","size":"256x256","stream":true,"partial_images":2}"#) { r in
                XCTAssertEqual(r.headers[.contentType], "text/event-stream")
                let ev = self.events(r)
                XCTAssertEqual(ev.map(\.0), ["image_generation.partial_image", "image_generation.partial_image", "image_generation.completed"])
                XCTAssertEqual(ev.map { $0.1["type"] as? String }, ev.map(\.0))
                XCTAssertEqual(ev.prefix(2).map { $0.1["partial_image_index"] as? Int }, [0, 1])
                for (_, j) in ev {
                    XCTAssertEqual(j["size"] as? String, "256x256")
                    XCTAssertEqual(j["background"] as? String, "opaque")
                    XCTAssertNotNil(j["created_at"]); XCTAssertNotNil(j["b64_json"])
                }
                XCTAssertNotNil(ev[2].1["usage"])
            }
        }
    }

    private func form(fields: [String: String] = [:], files: [(name: String, data: Data, contentType: String?)]) -> (ByteBuffer, String) {
        let b = "XBOUNDARY"
        var d = Data()
        for (k, v) in fields { d += Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
        for f in files {
            d += Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(f.name)\"; filename=\"f.png\"\r\n".utf8)
            if let ct = f.contentType { d += Data("Content-Type: \(ct)\r\n".utf8) }
            d += Data("\r\n".utf8) + f.data + Data("\r\n".utf8)
        }
        d += Data("--\(b)--\r\n".utf8)
        return (ByteBuffer(data: d), "multipart/form-data; boundary=\(b)")
    }

    private func edit(_ c: some TestClientProtocol, _ body: (ByteBuffer, String), check: @escaping @Sendable (TestResponse) throws -> Void) async throws {
        try await c.execute(uri: "/v1/images/edits", method: .post, headers: [.contentType: body.1], body: body.0) { try check($0) }
    }

    func testEditSingleImage() async throws {
        try await makeApp().test(.router) { c in
            let body = self.form(fields: ["prompt": "edit", "size": "256x256", "model": "flux2-klein-4b"],
                                 files: [("image", Self.png(32, 32), nil)])
            try await self.edit(c, body) { r in
                XCTAssertEqual(r.status, .ok)
                let d = Data(base64Encoded: ((try self.decode(r)["data"] as! [[String: Any]])[0]["b64_json"] as! String))!
                XCTAssertEqual(Self.pixelSize(d)?.0, 256)
            }
        }
    }

    func testEditMultipleImagesMaskAndStream() async throws {
        try await makeApp().test(.router) { c in
            let body = self.form(fields: ["prompt": "edit", "size": "256x256", "stream": "true", "partial_images": "1"],
                                 files: [("image[]", Self.png(32, 32), "image/png"), ("image[]", Self.png(32, 32), nil),
                                         ("mask", Self.png(32, 32), "image/png")])
            try await self.edit(c, body) { r in
                XCTAssertEqual(self.events(r).map(\.0), ["image_edit.partial_image", "image_edit.completed"])
            }
        }
    }

    func testEditRequiresImage() async throws {
        try await makeApp().test(.router) { c in
            try await self.edit(c, self.form(fields: ["prompt": "x"], files: [])) { XCTAssertEqual($0.status, .badRequest) }
        }
    }

    func testEditWithNonEditModelIs400() async throws {
        try await makeApp().test(.router) { c in
            let body = self.form(fields: ["prompt": "e", "model": "z-image-turbo"], files: [("image", Self.png(32, 32), nil)])
            try await self.edit(c, body) { XCTAssertEqual($0.status, .badRequest) }
        }
    }

    func testNoImageModelIs503() async throws {
        try await makeApp(downloaded: []).test(.router) { c in
            try await self.post(c, #"{"prompt":"x"}"#) { XCTAssertEqual($0.status, .serviceUnavailable) }
        }
    }

    func testBadInputs() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, #"{"prompt":"x","size":"100x100"}"#) { XCTAssertEqual($0.status, .badRequest) }
            try await self.post(c, #"{"size":"256x256"}"#) { XCTAssertEqual($0.status, .badRequest) }
            try await self.post(c, #"{"prompt":"x","n":9}"#) { XCTAssertEqual($0.status, .badRequest) }
            try await self.post(c, #"{"prompt":"x","model":"nope"}"#) { XCTAssertEqual($0.status, .badRequest) }
        }
    }
}
