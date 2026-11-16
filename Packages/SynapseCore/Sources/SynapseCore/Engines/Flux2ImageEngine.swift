import Flux2Core
import Foundation
import ImageIO
import MLX
import UniformTypeIdentifiers

/// FLUX.2 klein (4B / 9B) through the vendored Flux2Swift pipeline, loading the diffusers-layout folder in place.
public actor Flux2ImageEngine: ImageEngine {
    private static let maxReferences = 3
    private var pipeline: Flux2Pipeline?
    private let model: Flux2Model
    private let encoderDir: URL

    public init(spec: ModelSpec, folder: URL) async throws {
        switch spec.id {
        case "flux2-klein-4b": model = .klein4B
        case "flux2-klein-9b": model = .klein9B
        default: throw EngineError.unsupported("\(spec.displayName) is not a FLUX.2 klein model")
        }
        // The library wants config.json + tokenizer.json + weights in one directory; diffusers splits them.
        let dir = FileManager.default.temporaryDirectory.appending(path: "synapse-flux2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for sub in ["text_encoder", "tokenizer"] {
            let src = folder.appending(path: sub)
            for name in try FileManager.default.contentsOfDirectory(atPath: src.path) {
                let link = dir.appending(path: name)
                if !FileManager.default.fileExists(atPath: link.path) {
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src.appending(path: name))
                }
            }
        }
        encoderDir = dir

        // Quantization: transformer is quantized on load to 8-bit affine (qint8; ~4 GB for 4B, ~9 GB for 9B) so it fits
        // 16 GB Macs. The library never holds encoder and transformer together, so the Qwen3 encoder stays bf16
        // (as shipped, nothing to download or convert) and is dropped before the transformer loads.
        // qint8's registry slot is overridden to our bf16 folder; the library quantizes it on the fly.
        let quant = Flux2QuantizationConfig(textEncoder: .bf16, transformer: .qint8)
        let variant = ModelRegistry.TransformerVariant.variant(for: model, quantization: .qint8)
        try ModelRegistry.setPathOverride(folder.appending(path: "transformer"), for: .transformer(variant))
        try ModelRegistry.setPathOverride(folder.appending(path: "vae"), for: .vae(.standard))

        let pipeline = Flux2Pipeline(model: model, quantization: quant, vaeVariant: .standard, kleinEncoderPath: dir)
        try await pipeline.loadModels()
        self.pipeline = pipeline
    }

    public func generate(_ request: ImageRequest, progress: @escaping @Sendable (ImageProgress) -> Void) async throws -> Data {
        guard let pipeline else { throw EngineError.unsupported("FLUX.2 engine is unloaded") }
        try request.validate()
        guard request.inputImages.count <= Self.maxReferences else {
            throw ImageError.invalidRequest("FLUX.2 klein accepts at most \(Self.maxReferences) reference images.")
        }
        let steps = request.steps ?? model.defaultSteps
        let guidance = request.guidance ?? model.defaultGuidance
        let onProgress: Flux2ProgressCallback = { step, total in progress(ImageProgress(step: step, totalSteps: total)) }
        let image: CGImage
        if request.inputImages.isEmpty {
            image = try await pipeline.generateTextToImage(
                prompt: request.prompt, height: request.height, width: request.width, steps: steps,
                guidance: guidance, seed: request.seed, onProgress: onProgress)
        } else {
            image = try await pipeline.generateImageToImage(
                prompt: request.prompt, imageData: request.inputImages, height: request.height, width: request.width,
                steps: steps, guidance: guidance, seed: request.seed, onProgress: onProgress)
        }
        try Task.checkCancellation()
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError.unsupported("PNG encoder unavailable")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.unsupported("PNG encoding failed") }
        return out as Data
    }

    public func unload() async {
        await pipeline?.clearAll()
        pipeline = nil
        try? FileManager.default.removeItem(at: encoderDir)
    }
}
