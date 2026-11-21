import AVFoundation
import Foundation
import ImageIO
import XCTest
@testable import SynapseCore

private actor RecordingEngine: VideoEngine {
    var seen: [VideoRequest] = []
    func generate(_ r: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        seen.append(r)
        try await VideoFile.writeSolidColor(to: output, width: 64, height: 64, frames: 2, fps: 24)
    }
}

final class MiniMaxH3Tests: XCTestCase {
    func testLoRAsAreAppliedToTheClipThatChoseThem() async throws {
        defer { Catalog.setCustom([]) }
        Catalog.setCustom([CustomModel(repo: "org/loras", engine: .videogen, displayName: "vhs", approxMB: 1, ramGB: nil,
                                       files: ["styles/vhs.safetensors"], baseModel: "minimax-h3")])
        let store = try TestSupport.store(downloaded: ["minimax-h3", "minimax-h3-turbo", "org/loras/styles/vhs", "ltx-2.3-distilled"])
        let engine = RecordingEngine()
        let videos = VideoService(store: store, models: ModelManager(), engineFactory: { _, _ in engine })
        let h3 = try XCTUnwrap(Catalog.spec("minimax-h3")), ltx = try XCTUnwrap(Catalog.spec("ltx-2.3-distilled"))
        XCTAssertFalse(Catalog.all.filter(\.isVideoGen).contains { $0.id == "minimax-h3-turbo" }, "a LoRA is not a model to pick")

        let patched = await videos.create(model: h3, request: VideoRequest(prompt: "fox", width: 64, height: 64, frames: 9,
                                                                           loras: [LoRAUse("minimax-h3-turbo"), LoRAUse("org/loras/styles/vhs", strength: 0.6)]))
        let plain = await videos.create(model: h3, request: VideoRequest(prompt: "fox", width: 64, height: 64, frames: 9))
        for _ in 0..<200 where await [patched.id, plain.id].asyncAll({ await videos.job($0)?.status == .completed }) == false {
            try await Task.sleep(for: .milliseconds(20))
        }
        let seen = await engine.seen, root = await store.root
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].applied, [
            AppliedLoRA(file: root.appending(path: "minimax-h3-turbo/loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors"), strength: 1),
            AppliedLoRA(file: root.appending(path: "org/loras/styles/vhs/styles/vhs.safetensors"), strength: 0.6)])
        XCTAssertEqual(seen[1].applied, [], "the next clip runs the base alone")

        await XCTAssertThrowsErrorAsync(try await videos.addOnFile("minimax-h3-turbo", for: ltx), "a LoRA only patches its own base")
        let bare = VideoService(store: try TestSupport.store(downloaded: ["minimax-h3"]), models: ModelManager(), engineFactory: { _, _ in engine })
        await XCTAssertThrowsErrorAsync(try await bare.addOnFile("minimax-h3-turbo", for: h3), "not downloaded")
    }

    func testArgumentsSwapTheLoRAsInAndOut() {
        let folder = URL(fileURLWithPath: "/m/minimax-h3"), out = URL(fileURLWithPath: "/t/out.webp"), dir = URL(fileURLWithPath: "/t/loras")
        var r = VideoRequest(prompt: "a fox", width: 500, height: 300, frames: 25, seed: 7)
        let base = MiniMaxH3.arguments(r, folder: folder, set: MiniMaxH3.small, output: out, startImage: nil, loraDir: dir)
        XCTAssertEqual(base.last, "a fox")
        XCTAssertEqual(base[base.firstIndex(of: "--steps")! + 1], "20")
        XCTAssertEqual(base[base.firstIndex(of: "-W")! + 1], "480", "width snaps down to a multiple of 32")
        XCTAssertFalse(base.contains("--lora-model-dir"))
        XCTAssertTrue(base.contains("te=cpu"), "the int8 encoder runs on the CPU")

        r.applied = [AppliedLoRA(file: URL(fileURLWithPath: "/m/turbo/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors"), strength: 1),
                     AppliedLoRA(file: URL(fileURLWithPath: "/m/vhs/vh5tape-comfyui.safetensors"), strength: 0.75)]
        let both = MiniMaxH3.arguments(r, folder: folder, set: MiniMaxH3.small, output: out, startImage: nil, loraDir: dir)
        XCTAssertEqual(both.last, "a fox <lora:lora0:1> <lora:lora1:0.75>")
        XCTAssertEqual(both[both.firstIndex(of: "--lora-model-dir")! + 1], "/t/loras")
        XCTAssertEqual(both[both.firstIndex(of: "--steps")! + 1], "4", "the distilled LoRA sets the schedule")
        r.applied.removeFirst()
        let style = MiniMaxH3.arguments(r, folder: folder, set: MiniMaxH3.small, output: out, startImage: nil, loraDir: dir)
        XCTAssertEqual(style[style.firstIndex(of: "--steps")! + 1], "20")
    }

    func testDownloadSetFollowsMemory() {
        XCTAssertEqual(MiniMaxH3.files(physicalMemory: 16 << 30).transformer.path, "minimax_h3_fl2va_pruned-Q2_K.gguf")
        XCTAssertEqual(MiniMaxH3.files(physicalMemory: 96 << 30).encoder.path, "qwen3vl_32b_minimax_h3-Q4_K_M.gguf")
    }

    /// sd.cpp hands over an animated image and a WAV; the clip must carry both.
    func testEncodeFramesAndSoundtrackToMP4() async throws {
        let dir = try TestSupport.tempDir()
        let frames = dir.appending(path: "out.gif"), wav = dir.appending(path: "out.wav"), mp4 = dir.appending(path: "out.mp4")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(frames as CFURL, "com.compuserve.gif" as CFString, 12, nil))
        for i in 0..<12 {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: Double(i) / 12, green: 0.3, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try PCM.wav16((0..<16000).map { sin(Float($0) * 0.05) * 0.3 }, rate: 32000).write(to: wav)
        try await VideoFile.encode(frames: frames, fps: 24, audio: wav, to: mp4)
        let asset = AVURLAsset(url: mp4)
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 0.5, accuracy: 0.05)
    }

    /// Lines from a real 4-step run on a 16 GB M4.
    func testProgressCoversSamplingThenDecoding() {
        let p = H3Progress()
        XCTAssertNil(p.feed("[I] sampling using Euler method --- request.cpp:478"))
        XCTAssertEqual(p.feed("  |============>                                     | 1/4 - 162.60s/it - ETA 08:07"), 0.1)
        XCTAssertEqual(p.feed("[I] sampling completed, taking 272.64s --- video.cpp:2028"), 0.4)
        XCTAssertEqual(try XCTUnwrap(p.feed("  |=========================| 2/4 - 120.00s/it")), 0.7, accuracy: 1e-9)
    }
}

private extension Array {
    func asyncAll(_ test: (Element) async -> Bool) async -> Bool {
        for e in self where await !test(e) { return false }
        return true
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error: \(message)", file: file, line: line) } catch {}
}

/// Real MiniMax H3 through `VideoService`, with the Turbo LoRA stacked on a style LoRA added from a Hugging Face
/// link. SYNAPSE_E2E=1; downloads what is missing (about 16 GB), then takes about 10 minutes on a 16 GB M4.
final class MiniMaxH3E2ETests: XCTestCase {
    func testTurboPlusAddedLoRAClipWithSound() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let store = ModelStore(root: env["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot)
        let vhs = try await HFModelInspector.inspect("https://huggingface.co/KennethFal/vh5tape-vhs-lora-minimax-h3/blob/main/vh5tape-comfyui.safetensors",
                                                     token: HFDownloader.cliToken()).model
        XCTAssertEqual(vhs.baseModel, "minimax-h3")
        Catalog.setCustom([vhs])
        defer { Catalog.setCustom([]) }
        for id in ["minimax-h3", "minimax-h3-turbo", vhs.id] {
            _ = try await store.download(id, token: HFDownloader.cliToken()) { _ in }
        }
        let videos = VideoService(store: store, models: ModelManager())
        let h3 = try XCTUnwrap(Catalog.spec("minimax-h3"))
        let job = await videos.create(model: h3, request: VideoRequest(
            prompt: "vh5tape, a red fox trotting through fresh snow in a pine forest, soft morning light, gentle wind sounds.",
            width: 480, height: 288, frames: VideoService.frames(seconds: 1), seed: 42,
            loras: [LoRAUse("minimax-h3-turbo"), LoRAUse(vhs.id, strength: 0.8)]))
        var done = job
        let started = Date()
        while done.status != .completed && done.status != .failed {
            try await Task.sleep(for: .seconds(10))
            let latest = await videos.job(job.id)
            done = try XCTUnwrap(latest)
        }
        print("H3 turbo+vhs clip: \(done.status) in \(Int(Date().timeIntervalSince(started))) s \(done.error ?? "")")
        XCTAssertEqual(done.status, .completed, done.error ?? "")
        let asset = AVURLAsset(url: try XCTUnwrap(done.file))
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1, "H3 makes a soundtrack")
        XCTAssertGreaterThan(seconds, 1)
        print("H3 clip at \(done.file!.path)")
    }
}
