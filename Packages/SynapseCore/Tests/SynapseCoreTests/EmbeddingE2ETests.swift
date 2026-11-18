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
        let r = try await svc.embed(model: spec, inputs: ([query] + docs).map(EmbeddingInput.text))
        print(String(format: "[embed] %d texts, %d tokens in %.2f s, dim %d", r.vectors.count, r.promptTokens,
                     Date().timeIntervalSince(start), r.vectors[0].count))
        for v in r.vectors { XCTAssertEqual(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-2) }
        let paris = EmbeddingService.cosine(r.vectors[0], r.vectors[1])
        let bananas = EmbeddingService.cosine(r.vectors[0], r.vectors[2])
        print(String(format: "[embed] cosine paris %.3f, bananas %.3f", paris, bananas))
        XCTAssertGreaterThan(paris, bananas + 0.1)
    }

    /// Image models: each image is closest to its own caption, and text-to-text still ranks Paris above bananas.
    func testImageModelsMatchImagesToTheirCaptions() async throws {
        let (svc, store) = try service()
        let downloaded = await store.downloaded
        let models = EmbeddingService.imageModels.sorted().filter(downloaded.contains)
        guard !models.isEmpty else { throw XCTSkip("no image embedding model downloaded") }
        let zebra = try Data(contentsOf: TestSupport.fixture("zebra.jpg")), penguin = try Data(contentsOf: TestSupport.fixture("penguin.png"))
        let captions = ["a zebra", "a penguin", "a red sports car"]
        for id in models {
            let spec = try await svc.resolveEmbedding(id, images: true)
            let start = Date()
            let r = try await svc.embed(model: spec, inputs: [EmbeddingInput(image: zebra), EmbeddingInput(image: penguin)]
                                        + captions.map(EmbeddingInput.text) + ([query] + docs).map(EmbeddingInput.text))
            let v = r.vectors
            print("[embed-image] \(id): \(r.promptTokens) prompt tokens")
            XCTAssertGreaterThan(r.promptTokens, 8, "\(id) reports usage")
            let row = { (i: Int) in (2..<5).map { EmbeddingService.cosine(v[i], v[$0]) } }
            print(String(format: "[embed-image] %@: %.1f s, dim %d; zebra→captions %@; penguin→captions %@", id, Date().timeIntervalSince(start),
                         v[0].count, row(0).map { String(format: "%.2f", $0) }.joined(separator: " "),
                         row(1).map { String(format: "%.2f", $0) }.joined(separator: " ")))
            XCTAssertEqual(row(0).enumerated().max { $0.element < $1.element }?.offset, 0, "\(id): zebra image → \"a zebra\"")
            XCTAssertEqual(row(1).enumerated().max { $0.element < $1.element }?.offset, 1, "\(id): penguin image → \"a penguin\"")
            let paris = EmbeddingService.cosine(v[5], v[6]), bananas = EmbeddingService.cosine(v[5], v[7])
            print(String(format: "[embed-image] %@: text paris %.2f, bananas %.2f", id, paris, bananas))
            XCTAssertGreaterThan(paris, bananas, id)
            if id == "qwen3-vl-embedding-2b" {
                // One vector for an image and its caption together, nearer the zebra than the penguin.
                let both = try await svc.embed(model: spec, inputs: [EmbeddingInput(text: "a zebra", image: zebra)]).vectors[0]
                print(String(format: "[embed-image] image+text item: zebra %.2f, penguin %.2f",
                             EmbeddingService.cosine(both, v[0]), EmbeddingService.cosine(both, v[1])))
                XCTAssertGreaterThan(EmbeddingService.cosine(both, v[0]), EmbeddingService.cosine(both, v[1]))
            }
        }
    }

    /// Qwen3-VL embeds a video (as 8 frames) nearest its caption.
    func testQwen3VLEmbedsAVideo() async throws {
        let (svc, store) = try service()
        guard await store.downloaded.contains("qwen3-vl-embedding-2b") else { throw XCTSkip("qwen3-vl-embedding-2b not downloaded") }
        let spec = try await svc.resolveEmbedding(nil, video: true)
        let frames = try await VideoFile.frames(of: TestSupport.fixture("zebra.mp4"), count: 8)
        XCTAssertEqual(frames.count, 8)
        let start = Date()
        let captions = ["a zebra", "a penguin", "a red sports car"]
        let r = try await svc.embed(model: spec, inputs: [EmbeddingInput(videoFrames: frames)] + captions.map(EmbeddingInput.text))
        let v = r.vectors
        print("[embed-video] \(r.promptTokens) prompt tokens")
        let sims = (1...3).map { EmbeddingService.cosine(v[0], v[$0]) }
        print(String(format: "[embed-video] %@: %.1f s; video→captions %@", spec.id, Date().timeIntervalSince(start),
                     sims.map { String(format: "%.2f", $0) }.joined(separator: " ")))
        XCTAssertEqual(sims.enumerated().max { $0.element < $1.element }?.offset, 0)
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
