import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// Vectors derived from the text so routes can be checked without a model: [count of "a", count of "b", 1, 0].
private struct FakeEmbeddingBackend: EmbeddingBackend {
    func embed(_ spec: ModelSpec, folder: URL, texts: [String]) async throws -> EmbeddingResult {
        let vectors = texts.map { t in
            EmbeddingService.normalized([Float(t.filter { $0 == "a" }.count), Float(t.filter { $0 == "b" }.count), 1, 0])
        }
        return EmbeddingResult(vectors: vectors, promptTokens: texts.reduce(0) { $0 + $1.count })
    }
    /// Score = shared characters with the query, so ranking is predictable.
    func scores(_ spec: ModelSpec, folder: URL, query: String, documents: [String]) async throws -> [Double] {
        documents.map { Double(Set($0).intersection(Set(query)).count) }
    }
}

final class EmbeddingAPITests: XCTestCase, @unchecked Sendable {
    private func makeApp(downloaded: [String] = ["qwen3-embedding-0.6b", "qwen3-reranker-0.6b"]) throws -> Application<RouterResponder<SynapseContext>> {
        let store = try TestSupport.store(downloaded: downloaded)
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box,
                             engineFactory: { _, _ in FakeEngine() })
        let embeddings = EmbeddingService(store: store, backend: FakeEmbeddingBackend())
        return Application(router: buildRouter(queue: queue, store: store, settings: box, embeddings: embeddings))
    }

    private func post(_ c: some TestClientProtocol, _ path: String, _ body: String,
                      check: @escaping @Sendable (TestResponse, [String: Any]) throws -> Void) async throws {
        try await c.execute(uri: path, method: .post, headers: [.contentType: "application/json"], body: ByteBuffer(string: body)) { r in
            let obj = (try? JSONSerialization.jsonObject(with: Data(buffer: r.body))) as? [String: Any] ?? [:]
            try check(r, obj)
        }
    }

    private func floats(_ any: Any?) -> [Float] { (any as? [NSNumber])?.map(\.floatValue) ?? [] }

    func testFloatAndBase64AgreeAndAliasResolves() async throws {
        try await makeApp().test(.router) { c in
            let expected = EmbeddingService.normalized([2, 1, 1, 0])
            try await self.post(c, "/v1/embeddings", #"{"model":"text-embedding-3-small","input":["aab","b"]}"#) { r, o in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(o["object"] as? String, "list")
                XCTAssertEqual(o["model"] as? String, "qwen3-embedding-0.6b")
                let data = o["data"] as? [[String: Any]] ?? []
                XCTAssertEqual(data.map { $0["index"] as? Int }, [0, 1])
                XCTAssertEqual(data.first?["object"] as? String, "embedding")
                XCTAssertEqual(self.floats(data.first?["embedding"]), expected)
                XCTAssertEqual((o["usage"] as? [String: Any])?["prompt_tokens"] as? Int, 4)
            }
            try await self.post(c, "/v1/embeddings", #"{"input":["aab","b"],"encoding_format":"base64"}"#) { _, o in
                let b64 = ((o["data"] as? [[String: Any]])?.first?["embedding"] as? String) ?? ""
                let bytes = Data(base64Encoded: b64) ?? Data()
                let decoded = stride(from: 0, to: bytes.count, by: 4).map { i in
                    Float(bitPattern: UInt32(littleEndian: bytes[i..<i + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                }
                XCTAssertEqual(decoded, expected)
            }
        }
    }

    func testDimensionsTruncateAndRenormalize() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, "/v1/embeddings", #"{"input":"aab","dimensions":2}"#) { r, o in
                XCTAssertEqual(r.status, .ok)
                let v = self.floats((o["data"] as? [[String: Any]])?.first?["embedding"])
                XCTAssertEqual(v.count, 2)
                XCTAssertEqual(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-3)
            }
            try await self.post(c, "/v1/embeddings", #"{"input":"aab","dimensions":99}"#) { r, _ in XCTAssertEqual(r.status, .badRequest) }
        }
    }

    func testTokenArraysAndBadInputAreRefused() async throws {
        try await makeApp().test(.router) { c in
            try await self.post(c, "/v1/embeddings", #"{"input":[[1,2,3]]}"#) { r, o in
                XCTAssertEqual(r.status, .badRequest)
                XCTAssertTrue(((o["error"] as? [String: Any])?["message"] as? String ?? "").contains("check_embedding_ctx_length"))
            }
            try await self.post(c, "/v1/embeddings", #"{"input":"x","encoding_format":"int8"}"#) { r, _ in XCTAssertEqual(r.status, .badRequest) }
            try await self.post(c, "/v1/embeddings", #"{"input":"x","model":"qwen3-reranker-0.6b"}"#) { r, _ in XCTAssertEqual(r.status, .badRequest) }
        }
    }

    func testNoModelIsServiceUnavailable() async throws {
        try await makeApp(downloaded: []).test(.router) { c in
            try await self.post(c, "/v1/embeddings", #"{"input":"x"}"#) { r, _ in XCTAssertEqual(r.status, .serviceUnavailable) }
            try await self.post(c, "/v1/rerank", #"{"query":"x","documents":["y"]}"#) { r, _ in XCTAssertEqual(r.status, .serviceUnavailable) }
        }
    }

    func testRerankOrdersTopNAndReturnsDocuments() async throws {
        try await makeApp().test(.router) { c in
            let body = #"{"query":"abc","documents":["zzz",{"text":"abx"},"abc"],"top_n":2,"return_documents":true}"#
            try await self.post(c, "/v1/rerank", body) { r, o in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(o["model"] as? String, "qwen3-reranker-0.6b")
                let results = o["results"] as? [[String: Any]] ?? []
                XCTAssertEqual(results.map { $0["index"] as? Int }, [2, 1])
                XCTAssertEqual((results.first?["document"] as? [String: Any])?["text"] as? String, "abc")
                XCTAssertNotNil(results.first?["relevance_score"] as? Double)
            }
            try await self.post(c, "/v1/rerank", #"{"documents":["a"]}"#) { r, _ in XCTAssertEqual(r.status, .badRequest) }
        }
    }
}
