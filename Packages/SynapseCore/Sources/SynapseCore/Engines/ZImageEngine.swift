import CoreGraphics
import Foundation
import ImageIO
import MLX
import Tokenizers
import UniformTypeIdentifiers
import ZImage

/// Z-Image (Turbo and Base) via the vendored `ZImage` library.
public actor ZImageEngine: ImageEngine {
    /// The library's generator is a non-Sendable class; it is only touched by one detached run at a time
    /// (the actor serializes calls), so crossing the task boundary is safe.
    private final class Box: @unchecked Sendable {
        let generator: ZImageGenerator
        init(_ g: ZImageGenerator) { generator = g }
    }

    private var box: Box?
    private let isTurbo: Bool
    private let spec: ModelSpec
    /// The area the library's VAE decode was measured for (fp32 decode peaks ~28 GB at 1536^2).
    private static let maxPixels = 1536 * 1536

    public init(spec: ModelSpec, folder: URL) async throws {
        self.spec = spec
        isTurbo = spec.id.contains("turbo")
        let path = folder.path
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("vae").path) else {
            throw EngineError.unsupported("Z-Image snapshot not readable at \(path)")
        }
        let transformer = try ZImageWeights.loadTransformer(snapshotPath: path, dtype: .bfloat16)
        // 8-bit DiT: bf16 (~12 GB) plus the bf16 text encoder (~8 GB) does not fit a 16 GB machine; int8 halves
        // the DiT with negligible quality loss, and int4 is only worth it if int8 cannot run at all.
        ZImageWeights.quantizeDiT(transformer, bits: 8)
        let vae = try ZImageWeights.loadVAE(snapshotPath: path, dtype: .float32)   // fp32: VAE force_upcast
        let encoder = try ZImageWeights.loadTextEncoder(snapshotPath: path, dtype: .bfloat16)
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder.appendingPathComponent("tokenizer"))

        struct SchedulerConfig: Decodable { var shift: Float?; var use_dynamic_shifting: Bool? }
        let cfg = (try? Data(contentsOf: folder.appendingPathComponent("scheduler/scheduler_config.json")))
            .flatMap { try? JSONDecoder().decode(SchedulerConfig.self, from: $0) }
        // Turbo 3.0, Base 6.0 when the config is missing; the config wins otherwise.
        let shift = cfg?.shift ?? (isTurbo ? 3.0 : 6.0)
        box = Box(ZImageGenerator(
            transformer: transformer, vae: vae,
            textEncoder: ZImageTextEncoder(encoder: encoder, tokenizer: tokenizer),
            schedulerShift: shift, schedulerDynamic: cfg?.use_dynamic_shifting ?? false,
            transformerDtype: .bfloat16))
    }

    public func generate(_ request: ImageRequest, progress: @escaping @Sendable (ImageProgress) -> Void) async throws -> Data {
        guard let box else { throw EngineError.unsupported("\(spec.displayName) is unloaded") }
        let w = request.width, h = request.height
        guard w % 16 == 0, h % 16 == 0, w > 0, h > 0, w * h <= Self.maxPixels else {
            throw ImageError.invalidRequest("Z-Image supports sizes in multiples of 16 up to 1536x1536 pixels in area; got \(w)x\(h).")
        }
        let steps = request.steps ?? (isTurbo ? 8 : 30)
        let guidance = request.guidance ?? (isTurbo ? 0 : 4.0)
        let seed = request.seed ?? UInt64.random(in: 0...UInt64(UInt32.max))
        let input = try request.inputImages.first.map { try Self.decodeInput($0, width: w, height: h) }
        let prompt = request.prompt, negative = request.negativePrompt

        // The library call is synchronous and blocks for minutes: run it off the actor. Its denoise loop polls
        // Task.isCancelled, so cancel the detached task when ours is cancelled.
        let task = Task.detached(priority: .userInitiated) { () -> (pixels: [UInt8], width: Int, height: Int) in
            let onStep: (Int, Int) -> Void = { progress(ImageProgress(step: $0, totalSteps: $1)) }
            let g = box.generator
            let out = input.map {
                g.generateImg2Img(prompt: prompt, negativePrompt: negative, image: $0, width: w, height: h, steps: steps,
                                  guidanceScale: guidance, strength: 0.6, seed: seed, onStep: onStep)
            } ?? g.generate(prompt: prompt, negativePrompt: negative, width: w, height: h, steps: steps,
                            guidanceScale: guidance, seed: seed, onStep: onStep)
            MLX.Memory.clearCache()
            return out
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return try Self.encodePNG(result.pixels, width: result.width, height: result.height)
    }

    public func unload() async {
        box = nil
        MLX.Memory.clearCache()
    }

    /// Encoded image -> [1,3,H,W] in [-1,1], scaled to the target size.
    private static func decodeInput(_ data: Data, width: Int, height: Int) throws -> MLXArray {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ImageError.invalidRequest("Input image could not be decoded.") }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let n = width * height
        var rgb = [Float](repeating: 0, count: 3 * n)
        for p in 0..<n { for c in 0..<3 { rgb[c * n + p] = Float(buf[p * 4 + c]) / 127.5 - 1 } }
        return MLXArray(rgb, [1, 3, height, width])
    }

    private static func encodePNG(_ pixels: [UInt8], width: Int, height: Int) throws -> Data {
        guard pixels.count == width * height * 3,   // empty when the library skipped decode (cancelled)
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ImageError.invalidRequest("Z-Image produced no pixels.") }
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in 0..<(width * height) {
            buf[i * 4] = pixels[i * 3]; buf[i * 4 + 1] = pixels[i * 3 + 1]; buf[i * 4 + 2] = pixels[i * 3 + 2]; buf[i * 4 + 3] = 255
        }
        let out = NSMutableData()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { throw ImageError.invalidRequest("PNG encoding failed.") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.invalidRequest("PNG encoding failed.") }
        return out as Data
    }
}
