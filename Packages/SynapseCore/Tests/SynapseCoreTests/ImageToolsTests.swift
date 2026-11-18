import AVFoundation
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
            try await c.execute(uri: "/v1/images/upscale", method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                                body: self.form(zebra)) { r in XCTAssertEqual(r.status, .serviceUnavailable) }
        }
    }
}

/// `/v1/videos/transform` with `mask` runs Vision on every frame (nothing to download).
final class VideoTransformTests: XCTestCase, @unchecked Sendable {
    /// zebra.mp4 with en.m4a's speech under it, made with a passthrough export.
    static func zebraWithSound(in dir: URL) async throws -> URL {
        let mix = AVMutableComposition()
        let video = AVURLAsset(url: try TestSupport.fixture("zebra.mp4")), audio = AVURLAsset(url: try TestSupport.fixture("en.m4a"))
        let duration = try await video.load(.duration)
        try mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: try await video.loadTracks(withMediaType: .video)[0], at: .zero)
        try mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: try await audio.loadTracks(withMediaType: .audio)[0], at: .zero)
        let out = dir.appending(path: "zebra-sound.mp4")
        try await AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough)!.export(to: out, as: .mp4)
        return out
    }

    static func form(_ video: Data, _ fields: [String: String]) -> ByteBuffer {
        var body = ByteBuffer()
        for (k, v) in fields { body.writeString("--XyZ\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n") }
        body.writeString("--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.mp4\"\r\nContent-Type: video/mp4\r\n\r\n")
        body.writeBytes(video)
        body.writeString("\r\n--XyZ--\r\n")
        return body
    }

    /// Facts about a video: seconds, size, frames, whether it has sound, and the mean brightness of its middle frame.
    static func facts(_ url: URL) async throws -> (seconds: Double, size: CGSize, frames: Int, audio: Bool, brightness: Float) {
        let a = AVURLAsset(url: url)
        let track = try await a.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: a)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out); reader.startReading()
        var frames = 0
        while out.copyNextSampleBuffer() != nil { frames += 1 }
        let seconds = try await a.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: a)
        let cg = try await gen.image(at: CMTime(seconds: seconds / 2, preferredTimescale: 600)).image
        return (seconds, try await track.load(.naturalSize), frames, !(try await a.loadTracks(withMediaType: .audio)).isEmpty,
                CIContext().averageRGBA(CIImage(cgImage: cg))[0])
    }

    func testMaskVideoKeepsTimingSizeAndSound() async throws {
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await Self.zebraWithSound(in: dir)
        let store = try TestSupport.store(downloaded: [])
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box,
                             engineFactory: { _, _ in FakeEngine() })
        let video = try Data(contentsOf: source)
        let before = try await Self.facts(source)
        try await Application(router: buildRouter(queue: queue, store: store, settings: box)).test(.router) { c in
            try await c.execute(uri: "/v1/videos/transform", method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                                body: Self.form(video, ["operation": "mask"])) { r in
                XCTAssertEqual(r.status, .ok, String(buffer: r.body))
                XCTAssertEqual(r.headers[.contentType], "video/mp4")
                let out = dir.appending(path: "mask.mp4")
                try Data(buffer: r.body).write(to: out)
                let after = try await Self.facts(out)
                print("[video] mask: \(before) -> \(after)")
                XCTAssertEqual(after.seconds, before.seconds, accuracy: 0.1)
                XCTAssertEqual(after.size, before.size)
                XCTAssertEqual(after.frames, before.frames)
                XCTAssertTrue(after.audio, "the source's sound is kept")
                XCTAssertGreaterThan(after.brightness, 0.2); XCTAssertLessThan(after.brightness, 0.8)
            }
            try await c.execute(uri: "/v1/videos/transform", method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                                body: Self.form(video, ["operation": "restyle"])) { r in XCTAssertEqual(r.status, .badRequest) }
            try await c.execute(uri: "/v1/videos/transform", method: .post, headers: [.contentType: "multipart/form-data; boundary=XyZ"],
                                body: Self.form(video, ["operation": "depth"])) { r in XCTAssertEqual(r.status, .serviceUnavailable) }
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

extension ImageToolsE2ETests {
    /// Real-ESRGAN ×4: four times the size, and shrinking it back gives the input again (within 4% on average).
    func testUpscaleIsFourTimesAndFaithful() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        guard await store.downloaded.contains("real-esrgan-x4plus") else { throw XCTSkip("real-esrgan-x4plus not downloaded") }
        let images = ImageService(store: store, models: ModelManager(), engineFactory: ImageEngines.real)
        let zebra = try Data(contentsOf: TestSupport.fixture("zebra.jpg"))
        let start = Date()
        let (spec, png) = try await images.upscale(zebra, model: nil)
        let took = Date().timeIntervalSince(start)
        let up = try XCTUnwrap(CIImage(data: png)), src = try XCTUnwrap(CIImage(data: zebra))
        XCTAssertEqual(up.extent.size, CGSize(width: src.extent.width * 4, height: src.extent.height * 4))
        let back = up.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.25, kCIInputAspectRatioKey: 1])
        // Mean absolute difference per channel (8-bit averaging is too coarse for squared errors).
        let diff = back.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: src])
        let mad = CIContext().averageRGBA(diff.cropped(to: src.extent)).prefix(3).reduce(0, +) / 3
        print(String(format: "[upscale] %@: %.1f s for %.0f×%.0f -> %.0f×%.0f; shrunk back, mean difference %.3f", spec.id, took,
                     src.extent.width, src.extent.height, up.extent.width, up.extent.height, mad))
        if let dir = ProcessInfo.processInfo.environment["SYNAPSE_SCRATCH"] { try png.write(to: URL(fileURLWithPath: dir).appending(path: "zebra-x4.png")) }
        XCTAssertLessThan(mad, 0.04)
    }
}

extension ImageToolsE2ETests {
    /// Depth and ×4 video through the real models: same timing and frames, sound kept; upscaling uses general-x4v3.
    func testDepthAndUpscaleVideo() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        let images = ImageService(store: store, models: ModelManager(), engineFactory: ImageEngines.real)
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await VideoTransformTests.zebraWithSound(in: dir)
        let before = try await VideoTransformTests.facts(source)
        for op in [VideoOperation.depth, .upscale] {
            let out = dir.appending(path: "\(op.rawValue).mp4")
            let start = Date()
            let spec = try await images.transformVideo(source, to: out, operation: op, model: nil)
            let after = try await VideoTransformTests.facts(out)
            print(String(format: "[video] %@ with %@: %.1f s for %d frames; %@", op.rawValue, spec?.id ?? "-", Date().timeIntervalSince(start),
                         after.frames, "\(after)"))
            if let dir = ProcessInfo.processInfo.environment["SYNAPSE_SCRATCH"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir).appending(path: "zebra-\(op.rawValue).mp4"))
                try FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: dir).appending(path: "zebra-\(op.rawValue).mp4"))
            }
            XCTAssertEqual(after.frames, before.frames, op.rawValue)
            XCTAssertEqual(after.seconds, before.seconds, accuracy: 0.1)
            XCTAssertTrue(after.audio, op.rawValue)
            XCTAssertEqual(after.size, op == .upscale ? CGSize(width: before.size.width * 4, height: before.size.height * 4) : before.size)
            if op == .upscale { XCTAssertEqual(spec?.id, "real-esrgan-general-x4v3") }
        }
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
