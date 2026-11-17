import Foundation
@preconcurrency import MLX
@preconcurrency import MLXEmbedders
@preconcurrency import MLXLMCommon
@preconcurrency import MLXRerankers

public struct EmbeddingResult: Sendable, Equatable {
    public var vectors: [[Float]]
    public var promptTokens: Int
}

public struct RerankScore: Sendable, Equatable {
    public var index: Int
    public var score: Double
}

/// Runs a loaded embedding or reranking model. The real backend uses MLX; tests inject fakes.
public protocol EmbeddingBackend: Sendable {
    /// One unit-length vector per text, plus the total prompt tokens.
    func embed(_ spec: ModelSpec, folder: URL, texts: [String]) async throws -> EmbeddingResult
    /// One relevance score per document, in document order.
    func scores(_ spec: ModelSpec, folder: URL, query: String, documents: [String]) async throws -> [Double]
}

public enum EmbeddingError: Error, LocalizedError, Equatable {
    case noModel(kind: String), badInput(String)
    public var errorDescription: String? {
        switch self {
        case .noModel(let kind): return "No \(kind) model is downloaded. Download one in Models."
        case .badInput(let m): return m
        }
    }
}

/// `POST /v1/embeddings`, `POST /v1/rerank` and the Embed pane.
public actor EmbeddingService {
    public static let maxInputs = 256
    public static let maxTokensPerInput = 8192
    /// OpenAI clients often hard-code these names; they mean "the default local embedding model".
    static let embeddingAliases: Set<String> = ["", "text-embedding-3-small", "text-embedding-3-large", "text-embedding-ada-002"]

    private let store: ModelStore
    private let backend: any EmbeddingBackend

    init(store: ModelStore, backend: any EmbeddingBackend) {
        self.store = store; self.backend = backend
    }

    public init(store: ModelStore, models: ModelManager) {
        self.init(store: store, backend: MLXEmbeddingBackend(models: models))
    }

    public func resolveEmbedding(_ requested: String?) async throws -> ModelSpec {
        try await resolve(requested, kind: "embedding", aliases: Self.embeddingAliases) { $0.isEmbedding }
    }

    public func resolveReranker(_ requested: String?) async throws -> ModelSpec {
        try await resolve(requested, kind: "reranker", aliases: [""]) { $0.isReranker }
    }

    /// Explicit ids must be downloaded models of the right kind; nil or an alias picks the smallest downloaded one.
    private func resolve(_ requested: String?, kind: String, aliases: Set<String>,
                         _ matches: (ModelSpec) -> Bool) async throws -> ModelSpec {
        let downloaded = await store.downloaded
        if let id = requested, !aliases.contains(id) {
            guard let spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
            guard matches(spec) else { throw ResolveError.wrongKind(id) }
            guard downloaded.contains(id) else { throw ResolveError.notDownloaded(id) }
            return spec
        }
        guard let spec = Catalog.all.filter({ matches($0) && downloaded.contains($0.id) }).min(by: { $0.approxMB < $1.approxMB })
        else { throw EmbeddingError.noModel(kind: kind) }
        return spec
    }

    public func isLoaded(_ id: String) async -> Bool {
        await (backend as? MLXEmbeddingBackend)?.models.isLoaded(id) ?? false
    }

    public func embed(model spec: ModelSpec, inputs: [String], dimensions: Int? = nil) async throws -> EmbeddingResult {
        guard !inputs.isEmpty else { throw EmbeddingError.badInput("input must not be empty.") }
        guard inputs.count <= Self.maxInputs else { throw EmbeddingError.badInput("At most \(Self.maxInputs) inputs per request.") }
        if let d = dimensions, d < 1 { throw EmbeddingError.badInput("dimensions must be at least 1.") }
        var result = try await backend.embed(spec, folder: try await folder(spec), texts: inputs)
        if let d = dimensions {
            guard let full = result.vectors.first?.count, d <= full else {
                throw EmbeddingError.badInput("dimensions must be at most \(result.vectors.first?.count ?? 0) for \(spec.id).")
            }
            result.vectors = result.vectors.map { Self.normalized(Array($0.prefix(d))) }
        }
        return result
    }

    /// Scores sorted by relevance, highest first, cut to `topN`.
    public func rerank(model spec: ModelSpec, query: String, documents: [String], topN: Int? = nil) async throws -> [RerankScore] {
        guard !query.isEmpty else { throw EmbeddingError.badInput("query must not be empty.") }
        guard !documents.isEmpty else { throw EmbeddingError.badInput("documents must not be empty.") }
        guard documents.count <= Self.maxInputs else { throw EmbeddingError.badInput("At most \(Self.maxInputs) documents per request.") }
        if let n = topN, n < 1 { throw EmbeddingError.badInput("top_n must be at least 1.") }
        let scores = try await backend.scores(spec, folder: try await folder(spec), query: query, documents: documents)
        let ranked = scores.enumerated().map { RerankScore(index: $0.offset, score: $0.element) }
            .sorted { $0.score > $1.score }
        return topN.map { Array(ranked.prefix($0)) } ?? ranked
    }

    private func folder(_ spec: ModelSpec) async throws -> URL {
        guard let f = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        return f
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

/// MLX embedders and rerankers loaded through the ModelManager, run under the GPU gate.
struct MLXEmbeddingBackend: EmbeddingBackend {
    let models: ModelManager

    func embed(_ spec: ModelSpec, folder: URL, texts: [String]) async throws -> EmbeddingResult {
        let lease = try await models.lease(spec.id, as: EmbedderModelContainer.self, estimatedBytes: spec.estimatedBytes) {
            (try await EmbedderModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader()), unload: {})
        }
        defer { lease.release() }
        let container = lease.value
        return try await GPUGate.shared.run {
            var vectors: [[Float]] = []
            var tokens = 0
            // shortcut: one text per forward pass, so no padding or attention-mask handling; batch when throughput matters.
            for text in texts {
                let (vector, count): ([Float], Int) = try await container.perform { ctx in
                    let ids = ctx.tokenizer.encode(text: text, addSpecialTokens: true)
                    guard ids.count <= EmbeddingService.maxTokensPerInput else {
                        throw EmbeddingError.badInput("An input has \(ids.count) tokens; the limit is \(EmbeddingService.maxTokensPerInput).")
                    }
                    let input = MLXArray(ids.map(Int32.init)).expandedDimensions(axis: 0)
                    let out = ctx.pooling(ctx.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: nil),
                                          normalize: true, applyLayerNorm: false)
                    out.eval()
                    return (out.reshaped(-1).asArray(Float.self), ids.count)
                }
                vectors.append(vector)
                tokens += count
            }
            return EmbeddingResult(vectors: vectors, promptTokens: tokens)
        }
    }

    func scores(_ spec: ModelSpec, folder: URL, query: String, documents: [String]) async throws -> [Double] {
        let lease = try await models.lease(spec.id, as: RerankerContainer.self, estimatedBytes: spec.estimatedBytes) {
            (try await RerankerModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader()), unload: {})
        }
        defer { lease.release() }
        let container = lease.value
        return try await GPUGate.shared.run {
            let response = try await container.scores(query: query, documents: documents)
            var out = [Double](repeating: 0, count: documents.count)
            for r in response.results where r.index < out.count { out[r.index] = r.score }
            return out
        }
    }
}
