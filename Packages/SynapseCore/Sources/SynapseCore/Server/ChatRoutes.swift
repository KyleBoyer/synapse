import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

// OpenAI-compatible chat: POST /v1/chat/completions and POST /v1/responses (text + image input, optional SSE).

// MARK: Wire types (decoding)

/// A JSON value we only need to inspect loosely (OpenAI content can be a string or an array of parts).
enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v):
            if v.rounded() == v, abs(v) < 1e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
}

struct ChatCompletionRequest: Decodable {
    var model: String?
    var messages: [JSONValue]
    var max_tokens: Int?
    var max_completion_tokens: Int?
    var temperature: Float?
    var top_p: Float?
    var stream: Bool?
    var stream_options: JSONValue?
    var reasoning_effort: String?
}

struct ResponsesRequest: Decodable {
    var model: String?
    var input: JSONValue
    var instructions: String?
    var max_output_tokens: Int?
    var temperature: Float?
    var top_p: Float?
    var stream: Bool?
    var reasoning: JSONValue?
    var tools: [JSONValue]?
    var tool_choice: JSONValue?
}

/// A text or image piece of a message, before images are fetched.
enum ContentPart: Equatable {
    case text(String)
    case image(String)   // data: URL or http(s) URL
}

enum ChatParse {
    static func bad(_ m: String) -> HTTPError { HTTPError(.badRequest, message: m) }

    /// Chat Completions content: string, or [{type:"text",text}, {type:"image_url",image_url:{url}|"url"}].
    /// Responses content additionally uses input_text / output_text / input_image {image_url}.
    static func parts(_ content: JSONValue?) throws -> [ContentPart] {
        guard let content else { return [] }
        if let s = content.string { return [.text(s)] }
        if case .null = content { return [] }
        guard let items = content.array else { throw bad("Message content must be a string or an array of parts.") }
        return try items.map { item in
            switch item["type"]?.string {
            case "text", "input_text", "output_text":
                return .text(item["text"]?.string ?? "")
            case "image_url", "input_image":
                let url = item["image_url"]?.string ?? item["image_url"]?["url"]?.string
                guard let url else { throw bad("Image part is missing image_url.") }
                return .image(url)
            case let t:
                throw bad("Unsupported content part type '\(t ?? "nil")'.")
            }
        }
    }

    static func role(_ s: String?) throws -> ChatMessage.Role {
        switch s {
        case "system", "developer": return .system
        case "user": return .user
        case "assistant": return .assistant
        default: throw bad("Unsupported message role '\(s ?? "nil")'.")
        }
    }

    static func chatMessages(_ raw: [JSONValue]) throws -> [(ChatMessage.Role, [ContentPart])] {
        try raw.map { (try role($0["role"]?.string), try parts($0["content"])) }
    }

    /// Responses `input`: a string, or a list of message items ({role, content}) / bare content parts.
    static func responseMessages(_ input: JSONValue, instructions: String?) throws -> [(ChatMessage.Role, [ContentPart])] {
        var out: [(ChatMessage.Role, [ContentPart])] = []
        if let instructions, !instructions.isEmpty { out.append((.system, [.text(instructions)])) }
        if let s = input.string { return out + [(.user, [.text(s)])] }
        guard let items = input.array else { throw bad("input must be a string or an array.") }
        for item in items {
            if item["role"] != nil {
                out.append((try role(item["role"]?.string), try parts(item["content"])))
            } else if let type = item["type"]?.string, type != "message" {
                out.append((.user, try parts(.array([item]))))
            } else {
                throw bad("Unsupported input item.")
            }
        }
        return out
    }
}

/// Turns parsed parts into ChatMessages, fetching image bytes. Remote fetches are capped in size and time.
enum ImageFetcher {
    static let maxBytes = 20 * 1024 * 1024

    static func load(_ url: String) async throws -> Data {
        if url.hasPrefix("data:") {
            guard let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters)
            else { throw ChatParse.bad("Image data URL must be base64 encoded.") }
            guard data.count <= maxBytes else { throw ChatParse.bad("Image is larger than 20 MB.") }
            return data
        }
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased()) else {
            throw ChatParse.bad("Image URL must be a data: URL or http(s) URL.")
        }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Synapse", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw ChatParse.bad("Could not fetch image \(url).")
        }
        guard data.count <= maxBytes else { throw ChatParse.bad("Image is larger than 20 MB.") }
        return data
    }

    static func messages(_ parsed: [(ChatMessage.Role, [ContentPart])]) async throws -> [ChatMessage] {
        var out: [ChatMessage] = []
        for (role, parts) in parsed {
            var text: [String] = []
            var images: [Data] = []
            for p in parts {
                switch p {
                case .text(let t): text.append(t)
                case .image(let u): images.append(try await load(u))
                }
            }
            out.append(ChatMessage(role: role, text: text.joined(separator: "\n"), images: images))
        }
        return out
    }
}

// MARK: Wire types (encoding)

struct ChatUsageWire: Encodable {
    var prompt_tokens: Int, completion_tokens: Int, total_tokens: Int
    init(_ u: ChatUsage) { prompt_tokens = u.promptTokens; completion_tokens = u.completionTokens; total_tokens = u.totalTokens }
}

struct ChatCompletionWire: Encodable {
    struct Choice: Encodable {
        struct Message: Encodable { var role = "assistant"; var content: String; var refusal: String? = nil }
        var index = 0
        var message: Message
        var logprobs: String? = nil
        var finish_reason: String
    }
    var id: String
    var object = "chat.completion"
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: ChatUsageWire
}

struct ChatChunkWire: Encodable {
    struct Choice: Encodable {
        struct Delta: Encodable { var role: String?; var content: String? }
        var index = 0
        var delta: Delta
        var logprobs: String? = nil
        var finish_reason: String?
    }
    var id: String
    var object = "chat.completion.chunk"
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: ChatUsageWire?
}

struct ResponseWire: Encodable {
    struct OutputText: Encodable { var type = "output_text"; var text: String; var annotations: [String] = [] }
    struct Message: Encodable {
        var type = "message"; var id: String; var status: String; var role = "assistant"; var content: [OutputText]
    }
    struct Usage: Encodable {
        var input_tokens: Int, output_tokens: Int, total_tokens: Int
        var input_tokens_details = ["cached_tokens": 0, "cache_write_tokens": 0]
        var output_tokens_details = ["reasoning_tokens": 0]
        init(_ u: ChatUsage) { input_tokens = u.promptTokens; output_tokens = u.completionTokens; total_tokens = u.totalTokens }
    }
    struct Incomplete: Encodable { var reason: String }
    var id: String
    var object = "response"
    var created_at: Int
    var status: String
    var model: String
    var output: [Message]
    var output_text: String
    var usage: Usage?
    var incomplete_details: Incomplete?
    var error: String? = nil
    var instructions: String?
    var max_output_tokens: Int?
    var temperature: Float?
    var top_p: Float?
    var parallel_tool_calls = false
    var tool_choice: JSONValue = .string("none")
    var tools: [JSONValue] = []
    var text = ["format": ["type": "text"]]
}

// MARK: Routes

func addChatRoutes(to g: RouterGroup<SynapseContext>, chat: ChatService, images: ImageService, settings: SettingsBox) {
    g.post("v1/chat/completions") { req, ctx in
        let raw = try await rawBody(req, ctx)
        if let proxied = try await proxyToVOOM(raw, path: "v1/chat/completions", chat: chat, settings: settings) { return proxied }
        let body = try decodeJSON(ChatCompletionRequest.self, raw)
        let spec = try await resolveChat(chat, body.model)
        let messages = try await ImageFetcher.messages(try ChatParse.chatMessages(body.messages))
        let options = ChatOptions(maxTokens: body.max_completion_tokens ?? body.max_tokens, temperature: body.temperature,
                                  topP: body.top_p, enableThinking: thinking(body.reasoning_effort))
        let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let created = Int(Date().timeIntervalSince1970)

        guard body.stream == true else {
            let r = try await chat.complete(model: spec, messages: messages, options: options)
            return json(ChatCompletionWire(id: id, created: created, model: spec.id, choices: [
                .init(message: .init(content: r.text), finish_reason: r.finishReason),
            ], usage: ChatUsageWire(r.usage)))
        }

        let includeUsage = body.stream_options?["include_usage"]?.bool == true
        let events = try await chat.stream(model: spec, messages: messages, options: options)
        return sse { write in
            func chunk(_ delta: ChatChunkWire.Choice.Delta, finish: String? = nil) -> ChatChunkWire {
                ChatChunkWire(id: id, created: created, model: spec.id, choices: [.init(delta: delta, finish_reason: finish)])
            }
            try await write(nil, chunk(.init(role: "assistant", content: "")))
            for try await event in events {
                switch event {
                case .delta(let s):
                    try await write(nil, chunk(.init(content: s)))
                case .toolCall:
                    break
                case .done(let finish, let usage):
                    try await write(nil, chunk(.init(), finish: finish))
                    if includeUsage {
                        try await write(nil, ChatChunkWire(id: id, created: created, model: spec.id, choices: [], usage: ChatUsageWire(usage)))
                    }
                }
            }
            try await writeRaw(write, "[DONE]")
        }
    }

    g.post("v1/responses") { req, ctx in
        let raw = try await rawBody(req, ctx)
        if let proxied = try await proxyToVOOM(raw, path: "v1/responses", chat: chat, settings: settings) { return proxied }
        let body = try decodeJSON(ResponsesRequest.self, raw)
        if let tools = body.tools, !tools.isEmpty {
            return try await respondWithImageTool(body, tools: tools, chat: chat, images: images)
        }
        let spec = try await resolveChat(chat, body.model)
        let messages = try await ImageFetcher.messages(try ChatParse.responseMessages(body.input, instructions: body.instructions))
        let effort = body.reasoning?["effort"]?.string
        let options = ChatOptions(maxTokens: body.max_output_tokens, temperature: body.temperature,
                                  topP: body.top_p, enableThinking: thinking(effort))
        let respID = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let msgID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let created = Int(Date().timeIntervalSince1970)

        @Sendable func response(status: String, text: String, usage: ChatUsage?, finish: String?) -> ResponseWire {
            let incomplete = finish == "length"
            let finalStatus = status == "completed" && incomplete ? "incomplete" : status
            return ResponseWire(
                id: respID, created_at: created, status: finalStatus, model: spec.id,
                output: status == "in_progress" ? [] : [.init(id: msgID, status: finalStatus, content: [.init(text: text)])],
                output_text: text, usage: usage.map(ResponseWire.Usage.init),
                incomplete_details: incomplete ? .init(reason: "max_output_tokens") : nil,
                instructions: body.instructions, max_output_tokens: body.max_output_tokens,
                temperature: body.temperature, top_p: body.top_p)
        }

        guard body.stream == true else {
            let r = try await chat.complete(model: spec, messages: messages, options: options)
            return json(response(status: "completed", text: r.text, usage: r.usage, finish: r.finishReason))
        }

        let events = try await chat.stream(model: spec, messages: messages, options: options)
        return sse { write in
            var seq = 0
            func event(_ type: String, _ fields: [String: any Encodable & Sendable]) async throws {
                var payload: [String: any Encodable & Sendable] = fields
                payload["type"] = type
                payload["sequence_number"] = seq
                seq += 1
                try await write(type, AnyEncodableDict(payload))
            }
            let item = ["type": "message", "id": msgID, "status": "in_progress", "role": "assistant"] as [String: String]
            let part = OutputTextPart(text: "")
            try await event("response.created", ["response": response(status: "in_progress", text: "", usage: nil, finish: nil)])
            try await event("response.in_progress", ["response": response(status: "in_progress", text: "", usage: nil, finish: nil)])
            try await event("response.output_item.added", ["output_index": 0, "item": AnyEncodableDict(item.mapValues { $0 }).withArray("content")])
            try await event("response.content_part.added", ["item_id": msgID, "output_index": 0, "content_index": 0, "part": part])
            var text = ""
            for try await e in events {
                switch e {
                case .delta(let s):
                    text += s
                    try await event("response.output_text.delta", ["item_id": msgID, "output_index": 0, "content_index": 0,
                                                                  "delta": s, "logprobs": [String]()])
                case .toolCall:
                    break
                case .done(let finish, let usage):
                    let final = response(status: "completed", text: text, usage: usage, finish: finish)
                    try await event("response.output_text.done", ["item_id": msgID, "output_index": 0, "content_index": 0,
                                                                 "text": text, "logprobs": [String]()])
                    try await event("response.content_part.done", ["item_id": msgID, "output_index": 0, "content_index": 0,
                                                                  "part": OutputTextPart(text: text)])
                    try await event("response.output_item.done", ["output_index": 0, "item": final.output[0]])
                    try await event(final.status == "completed" ? "response.completed" : "response.incomplete", ["response": final])
                }
            }
        }
    }
}

struct OutputTextPart: Encodable, Sendable { var type = "output_text"; var text: String; var annotations: [String] = [] }

/// Encodes a heterogeneous dictionary of Encodable values as a JSON object.
struct AnyEncodableDict: Encodable, Sendable {
    var values: [String: any Encodable & Sendable]
    init(_ values: [String: any Encodable & Sendable]) { self.values = values }

    func withArray(_ key: String) -> AnyEncodableDict {
        var copy = self
        copy.values[key] = [String]()
        return copy
    }

    struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (k, v) in values { try c.encode(v, forKey: Key(k)) }
    }
}

private func thinking(_ effort: String?) -> Bool {
    guard let effort else { return false }
    return !["none", "minimal"].contains(effort)
}

func resolveChat(_ chat: ChatService, _ model: String?) async throws -> ModelSpec {
    do { return try await chat.resolve(model) } catch let e as ResolveError {
        throw HTTPError(e == .noChatModel ? .serviceUnavailable : .badRequest, message: e.localizedDescription)
    }
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ req: Request, _ ctx: SynapseContext) async throws -> T {
    try decodeJSON(type, try await rawBody(req, ctx))
}

func rawBody(_ req: Request, _ ctx: SynapseContext) async throws -> Data {
    Data(buffer: try await req.body.collect(upTo: ctx.maxUploadSize))
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
        throw HTTPError(.badRequest, message: "Invalid JSON body: \(error.localizedDescription)")
    }
}

/// Forwards `voom:<model>` requests to the vOOM runtime with the prefix stripped; responses (including SSE)
/// stream back unchanged. Returns nil for every other model.
func proxyToVOOM(_ raw: Data, path: String, chat: ChatService, settings: SettingsBox) async throws -> Response? {
    guard var json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          let model = json["model"] as? String, model.hasPrefix(VOOMRuntime.modelPrefix) else { return nil }
    guard let checkout = settings.current.voomCheckout, !checkout.isEmpty else {
        throw HTTPError(.badRequest, message: "vOOM models need a vOOM checkout path in Settings.")
    }
    let runtime = VOOMRuntime.shared(checkout: checkout, models: chat.models)
    json["model"] = String(model.dropFirst(VOOMRuntime.modelPrefix.count))
    var request = URLRequest(url: await runtime.baseURL.appending(path: path), timeoutInterval: 3600)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: json)

    let lease = try await runtime.lease()
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do { (bytes, response) = try await URLSession.shared.bytes(for: request) } catch {
        lease.release()
        throw HTTPError(.badGateway, message: "vOOM request failed: \(error.localizedDescription)")
    }
    let http = response as? HTTPURLResponse
    let status = HTTPResponse.Status(code: http?.statusCode ?? 502)
    let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
    let body = ResponseBody { writer in
        defer { lease.release() }
        var chunk = [UInt8]()
        chunk.reserveCapacity(4096)
        for try await byte in bytes {
            chunk.append(byte)
            // Flush per line so SSE events reach the client as soon as vOOM emits them.
            if byte == 0x0A || chunk.count >= 4096 {
                try await writer.write(ByteBuffer(bytes: chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await writer.write(ByteBuffer(bytes: chunk)) }
        try await writer.finish(nil)
    }
    return Response(status: status, headers: [.contentType: contentType, .cacheControl: "no-cache"], body: body)
}

typealias SSEWrite = @Sendable (_ event: String?, _ payload: any Encodable & Sendable) async throws -> Void

/// Server-sent events. The producer runs in its own task and hands frames over a stream; if the client
/// disconnects, the write fails and the producer (and with it generation) is cancelled.
func sse(_ produce: @escaping @Sendable (SSEWrite) async throws -> Void) -> Response {
    let body = ResponseBody { writer in
        let (frames, sink) = AsyncStream.makeStream(of: String.self)
        let producer = Task {
            do {
                try await produce { event, payload in sink.yield(try sseFrame(event, payload)) }
            } catch is CancellationError {
            } catch {
                // Shape satisfies both SDK paths: Responses' typed `error` event and Chat Completions' `{"error":{...}}`.
                let message = error.localizedDescription
                let err = AnyEncodableDict(["type": "error", "code": "server_error", "message": message, "sequence_number": 0,
                                            "error": AnyEncodableDict(["message": message, "type": "server_error"])])
                if let f = try? sseFrame("error", err) { sink.yield(f) }
            }
            sink.finish()
        }
        do {
            for await frame in frames { try await writer.write(ByteBuffer(string: frame)) }
        } catch {
            producer.cancel()
            throw error
        }
        try await writer.finish(nil)
    }
    return Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"], body: body)
}

private func writeRaw(_ write: SSEWrite, _ raw: String) async throws {
    try await write("__raw__", raw)
}

private func sseFrame(_ event: String?, _ payload: any Encodable & Sendable) throws -> String {
    if event == "__raw__", let s = payload as? String { return "data: \(s)\n\n" }
    let data = try JSONEncoder().encode(payload)
    return (event.map { "event: \($0)\n" } ?? "") + "data: \(String(decoding: data, as: UTF8.self))\n\n"
}
