import Foundation
import Hummingbird

/// OpenAI `POST /v1/embeddings` body. `input` is a string or an array of strings.
struct EmbeddingRequest: Decodable {
    var model: String?
    var input: JSONValue
    var encoding_format: String?
    var dimensions: Int?
}

struct EmbeddingWire: Encodable {
    struct Item: Encodable {
        var object = "embedding"
        var index: Int
        var embedding: Vector
    }
    /// Floats, or base64 of little-endian Float32 bytes (the OpenAI Python SDK asks for base64 by default).
    enum Vector: Encodable {
        case floats([Float]), base64(String)
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .floats(let v): try c.encode(v)
            case .base64(let s): try c.encode(s)
            }
        }
    }
    struct Usage: Encodable { var prompt_tokens: Int; var total_tokens: Int }
    var object = "list"
    var data: [Item]
    var model: String
    var usage: Usage
}

/// Cohere/Jina-style `POST /v1/rerank` body. `documents` are strings or `{"text": ...}` objects.
struct RerankRequestBody: Decodable {
    var model: String?
    var query: String?
    var documents: [JSONValue]?
    var top_n: Int?
    var return_documents: Bool?
}

struct RerankWire: Encodable {
    struct Doc: Encodable { var text: String }
    struct Result: Encodable {
        var index: Int
        var relevance_score: Double
        var document: Doc?
    }
    struct Usage: Encodable { var total_tokens = 0 }
    var id: String
    var model: String
    var results: [Result]
    var usage = Usage()
}

func addEmbeddingRoutes(to g: RouterGroup<SynapseContext>, embeddings: EmbeddingService) {
    g.post("embeddings") { req, ctx in
        let body = try decodeJSON(EmbeddingRequest.self, try await rawBody(req, ctx))
        let inputs = try embeddingInputs(body.input)
        let format = body.encoding_format ?? "float"
        guard format == "float" || format == "base64" else {
            throw HTTPError(.badRequest, message: "encoding_format must be float or base64.")
        }
        do {
            let spec = try await embeddings.resolveEmbedding(body.model)
            let r = try await embeddings.embed(model: spec, inputs: inputs, dimensions: body.dimensions)
            let items = r.vectors.enumerated().map { i, v in
                EmbeddingWire.Item(index: i, embedding: format == "base64" ? .base64(base64Floats(v)) : .floats(v))
            }
            return json(EmbeddingWire(data: items, model: spec.id,
                                      usage: .init(prompt_tokens: r.promptTokens, total_tokens: r.promptTokens)))
        } catch let e as EmbeddingError {
            throw HTTPError(e == .noModel(kind: "embedding") ? .serviceUnavailable : .badRequest, message: e.localizedDescription)
        } catch let e as ResolveError {
            throw HTTPError(.badRequest, message: e.localizedDescription)
        }
    }

    g.post("rerank") { req, ctx in
        let body = try decodeJSON(RerankRequestBody.self, try await rawBody(req, ctx))
        guard let query = body.query, !query.isEmpty else { throw HTTPError(.badRequest, message: "query is required.") }
        let docs = try (body.documents ?? []).map { d -> String in
            if let s = d.string { return s }
            if let s = d["text"]?.string { return s }
            throw HTTPError(.badRequest, message: "documents must be strings or objects with a text field.")
        }
        do {
            let spec = try await embeddings.resolveReranker(body.model)
            let ranked = try await embeddings.rerank(model: spec, query: query, documents: docs, topN: body.top_n)
            let results = ranked.map {
                RerankWire.Result(index: $0.index, relevance_score: $0.score,
                                  document: body.return_documents == true ? .init(text: docs[$0.index]) : nil)
            }
            let id = "rerank-" + UUID().uuidString.lowercased()
            return json(RerankWire(id: id, model: spec.id, results: results))
        } catch let e as EmbeddingError {
            throw HTTPError(e == .noModel(kind: "reranker") ? .serviceUnavailable : .badRequest, message: e.localizedDescription)
        } catch let e as ResolveError {
            throw HTTPError(.badRequest, message: e.localizedDescription)
        }
    }
}

/// Text inputs only. Token-id arrays (what LangChain sends by default) are refused with how to turn them off.
func embeddingInputs(_ v: JSONValue) throws -> [String] {
    if let s = v.string { return [s] }
    guard let items = v.array else { throw HTTPError(.badRequest, message: "input must be a string or an array of strings.") }
    return try items.map { item in
        if let s = item.string { return s }
        if item.number != nil || item.array != nil {
            throw HTTPError(.badRequest, message: "Token-array input is not supported; send text. In LangChain set check_embedding_ctx_length=False.")
        }
        throw HTTPError(.badRequest, message: "input must be a string or an array of strings.")
    }
}

func base64Floats(_ v: [Float]) -> String {
    var data = Data(capacity: v.count * 4)
    for x in v { withUnsafeBytes(of: x.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    return data.base64EncodedString()
}
