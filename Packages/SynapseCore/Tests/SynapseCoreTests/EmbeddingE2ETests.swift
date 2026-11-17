import Foundation
@preconcurrency import MLXEmbedders
import XCTest
@testable import SynapseCore

/// Real embedding and reranking models. SYNAPSE_E2E=1 with qwen3-embedding-0.6b and qwen3-reranker-0.6b downloaded.
final class EmbeddingE2ETests: XCTestCase {
    private func service() throws -> (EmbeddingService, ModelStore) {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        return (EmbeddingService(store: store, models: ModelManager()), store)
    }

    private let query = "What is the capital of France?"
    private let docs = ["Paris is the capital of France.", "Bananas are yellow."]

    func testEmbeddingsRankParisAboveBananas() async throws {
        let (svc, store) = try service()
        let spec = try await svc.resolveEmbedding("qwen3-embedding-0.6b")
        // Last-token pooling needs the end-of-text token the tokenizer's post-processor appends.
        let maybeFolder = await store.folder(for: spec.id)
        let folder = try XCTUnwrap(maybeFolder)
        let container = try await EmbedderModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader())
        let (last, eot) = await container.perform { ctx in
            (ctx.tokenizer.encode(text: "hello", addSpecialTokens: true).last, ctx.tokenizer.convertTokenToId("<|endoftext|>"))
        }
        print("[embed] last token \(String(describing: last)), <|endoftext|> \(String(describing: eot))")
        XCTAssertEqual(last, eot, "the tokenizer must append <|endoftext|> for last-token pooling")

        let start = Date()
        let r = try await svc.embed(model: spec, inputs: [query] + docs)
        print(String(format: "[embed] %d texts, %d tokens in %.2f s, dim %d", r.vectors.count, r.promptTokens,
                     Date().timeIntervalSince(start), r.vectors[0].count))
        for v in r.vectors { XCTAssertEqual(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-2) }
        let paris = EmbeddingService.cosine(r.vectors[0], r.vectors[1])
        let bananas = EmbeddingService.cosine(r.vectors[0], r.vectors[2])
        print(String(format: "[embed] cosine paris %.3f, bananas %.3f", paris, bananas))
        XCTAssertGreaterThan(paris, bananas + 0.1)
    }

    func testRerankerPutsParisFirst() async throws {
        let (svc, _) = try service()
        let spec = try await svc.resolveReranker("qwen3-reranker-0.6b")
        let ranked = try await svc.rerank(model: spec, query: query, documents: docs.reversed())
        print("[rerank] \(ranked)")
        XCTAssertEqual(ranked.first?.index, 1)
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }
}
