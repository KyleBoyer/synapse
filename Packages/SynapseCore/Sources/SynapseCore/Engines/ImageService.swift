import Foundation
@preconcurrency import Vision

public struct ImageRequest: Sendable, Equatable {
    public var prompt: String
    public var negativePrompt: String?
    public var width: Int
    public var height: Int
    /// nil = the model's default.
    public var steps: Int?
    public var guidance: Float?
    public var seed: UInt64?
    /// Reference / source images for edits (encoded PNG/JPEG/...).
    public var inputImages: [Data]
    public var mask: Data?

    public init(prompt: String, negativePrompt: String? = nil, width: Int = 1024, height: Int = 1024, steps: Int? = nil,
                guidance: Float? = nil, seed: UInt64? = nil, inputImages: [Data] = [], mask: Data? = nil) {
        self.prompt = prompt; self.negativePrompt = negativePrompt; self.width = width; self.height = height
        self.steps = steps; self.guidance = guidance; self.seed = seed; self.inputImages = inputImages; self.mask = mask
    }

    public var isEdit: Bool { !inputImages.isEmpty }

    func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageError.invalidRequest("prompt is required.")
        }
        guard (256...2048).contains(width), (256...2048).contains(height), width % 16 == 0, height % 16 == 0 else {
            throw ImageError.badSize("\(width)x\(height)")
        }
        if let steps, !(1...1000).contains(steps) { throw ImageError.invalidRequest("steps must be between 1 and 1000.") }
        if let guidance, !guidance.isFinite || guidance < 0 { throw ImageError.invalidRequest("guidance must be finite and nonnegative.") }
    }
}

public struct ImageProgress: Sendable, Equatable {
    public var step: Int
    public var totalSteps: Int
    /// Optional low-cost preview (PNG) of the current latent, for streamed partial images.
    public var preview: Data?

    public init(step: Int, totalSteps: Int, preview: Data? = nil) {
        self.step = step; self.totalSteps = totalSteps; self.preview = preview
    }
}

public protocol ImageEngine: Actor {
    /// Returns one PNG-encoded image.
    func generate(_ request: ImageRequest, progress: @escaping @Sendable (ImageProgress) -> Void) async throws -> Data
    func unload() async
}

extension ImageEngine {
    public func unload() async {}
}

public enum ImageError: Error, LocalizedError, Equatable {
    case editUnsupported(String), badSize(String), invalidRequest(String), noImageModel
    public var errorDescription: String? {
        switch self {
        case .editUnsupported(let id): return "Model '\(id)' cannot edit images."
        case .badSize(let s): return "Unsupported size '\(s)'. Use WIDTHxHEIGHT with multiples of 16, or 'auto'."
        case .noImageModel: return "No image model is downloaded. Download one (e.g. flux2-klein-4b) in Models."
        case .invalidRequest(let message): return message
        }
    }
}

/// Runs image models through the shared ModelManager.
public actor ImageService {
    public typealias EngineFactory = @Sendable (ModelSpec, URL) async throws -> any ImageEngine

    private let store: ModelStore
    private let models: ModelManager
    private let engineFactory: EngineFactory

    public init(store: ModelStore, models: ModelManager, engineFactory: @escaping EngineFactory) {
        self.store = store; self.models = models; self.engineFactory = engineFactory
    }

    // MARK: Image to image without generation

    /// The subject cut out (or its mask), by macOS Vision; no model to download.
    public nonisolated func cutout(_ image: Data, output: ImageTools.Cutout) async throws -> Data {
        try await Task.detached { try ImageTools.cutout(image, output: output) }.value
    }

    private var depthModel: (id: String, model: VNCoreMLModel)?

    /// A depth map the size of the input (near is white). nil picks the downloaded depth model.
    public func depth(_ image: Data, model requested: String?) async throws -> (ModelSpec, Data) {
        let downloaded = await store.downloaded
        let spec: ModelSpec
        if let id = requested, !id.isEmpty {
            guard let s = Catalog.spec(id), s.isDepth else { throw ResolveError.wrongKind(id) }
            guard downloaded.contains(id) else { throw ResolveError.notDownloaded(id) }
            spec = s
        } else {
            guard let s = Catalog.all.first(where: { $0.isDepth && downloaded.contains($0.id) }) else { throw ImageToolError.noDepthModel }
            spec = s
        }
        if depthModel?.id != spec.id {
            guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
            depthModel = (spec.id, try ImageTools.loadDepthModel(folder: folder))
        }
        let model = depthModel!.model
        return (spec, try await Task.detached { try ImageTools.depth(image, model: model) }.value)
    }

    /// nil picks the smallest downloaded image model that can do the job.
    public func resolve(_ requested: String?, edit: Bool) async throws -> ModelSpec {
        let downloaded = await store.downloaded
        if let id = requested, !id.isEmpty, !id.hasPrefix("gpt-image"), id != "dall-e-3", id != "dall-e-2" {
            guard let spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
            guard spec.isImage else { throw ResolveError.wrongKind(id) }
            guard downloaded.contains(id) else { throw ResolveError.notDownloaded(id) }
            if edit && !spec.canEditImages { throw ImageError.editUnsupported(id) }
            return spec
        }
        guard let spec = Catalog.all.filter({ $0.isImage && downloaded.contains($0.id) && (!edit || $0.canEditImages) })
            .min(by: { $0.approxMB < $1.approxMB }) else { throw ImageError.noImageModel }
        return spec
    }

    public func isLoaded(_ id: String) async -> Bool { await models.isLoaded(id) }

    /// Generates `count` images sequentially (seed increments per image when given).
    public func generate(model spec: ModelSpec, request: ImageRequest, count: Int = 1,
                         progress: @escaping @Sendable (_ index: Int, ImageProgress) -> Void = { _, _ in }) async throws -> [Data] {
        try request.validate()
        guard (1...4).contains(count) else { throw ImageError.invalidRequest("count must be between 1 and 4.") }
        guard spec.isImage else { throw ResolveError.wrongKind(spec.id) }
        if request.isEdit && !spec.canEditImages { throw ImageError.editUnsupported(spec.id) }
        guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        let factory = engineFactory
        let lease = try await models.lease(spec.id, as: (any ImageEngine).self, estimatedBytes: spec.estimatedBytes) {
            let engine = try await factory(spec, folder)
            return (engine, unload: { await engine.unload() })
        }
        defer { lease.release() }
        var images: [Data] = []
        for i in 0..<count {
            try Task.checkCancellation()
            var r = request
            if let s = request.seed { r.seed = s &+ UInt64(i) }
            let engine = lease.value, req = r
            images.append(try await GPUGate.shared.run { try await engine.generate(req) { p in progress(i, p) } })
        }
        return images
    }

    /// Parses OpenAI `size` ("1024x1024", "auto"); dimensions are rounded to multiples of 16 within 256...2048.
    public static func parseSize(_ size: String?, default def: (Int, Int) = (1024, 1024)) throws -> (Int, Int) {
        guard let size, size != "auto", !size.isEmpty else { return def }
        let parts = size.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              (256...2048).contains(width), (256...2048).contains(height) else {
            throw ImageError.badSize(size)
        }
        return (width / 16 * 16, height / 16 * 16)
    }
}
