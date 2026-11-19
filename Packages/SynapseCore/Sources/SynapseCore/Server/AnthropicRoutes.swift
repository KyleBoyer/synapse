import Foundation
import Hummingbird

// Anthropic Messages API over the local chat models, so Anthropic SDK clients work with base_url pointed at Synapse.
// `claude-*` model ids fall back to the default chat model, the way OpenAI clients' `whisper-1` does for audio.

struct MessagesRequest: Decodable {
    var model: String?
    var max_tokens: Int?
    var messages: [JSONValue]
    var system: JSONValue?
    var temperature: Float?
    var top_p: Float?
    var top_k: Int?
    var stop_sequences: [String]?
    var stream: Bool?
    var tools: [JSONValue]?
    var tool_choice: JSONValue?
    var thinking: JSONValue?
}

enum AnthropicParse {
    static func messages(_ body: MessagesRequest) throws -> [(ChatMessage.Role, [ContentPart])] {
        var out: [(ChatMessage.Role, [ContentPart])] = []
        if let system = body.system {
            let parts = try blocks(system)
            if !parts.isEmpty { out.append((.system, parts)) }
        }
        for m in body.messages {
            switch m["role"]?.string {
            case "user": out.append((.user, try blocks(m["content"])))
            case "assistant": out.append((.assistant, try blocks(m["content"])))
            default: throw ChatParse.bad("messages: role must be 'user' or 'assistant'.")
            }
        }
        return out
    }

    /// Content blocks. Tool turns are written the way Qwen3.5's chat template renders them.
    static func blocks(_ content: JSONValue?) throws -> [ContentPart] {
        guard let content else { return [] }
        if let s = content.string { return [.text(s)] }
        guard let items = content.array else { throw ChatParse.bad("content must be a string or an array of content blocks.") }
        return try items.flatMap { b -> [ContentPart] in
            switch b["type"]?.string {
            case "text":
                return [.text(b["text"]?.string ?? "")]
            case "image":
                return [.image(try imageURL(b["source"]))]
            case "tool_use":
                guard let name = b["name"]?.string else { throw ChatParse.bad("tool_use block is missing name.") }
                guard case .object(let input) = b["input"] ?? .object([:]) else { throw ChatParse.bad("tool_use input must be an object.") }
                return [.text(ToolMarkup.call(name: name, arguments: input))]
            case "tool_result":
                let inner = try blocks(b["content"])
                let text = inner.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
                let images = inner.filter { if case .image = $0 { true } else { false } }
                return [.text(ToolMarkup.response(text))] + images
            case "thinking", "redacted_thinking":
                return []
            case let t:
                throw ChatParse.bad("Unsupported content block type '\(t ?? "nil")'.")
            }
        }
    }

    private static func imageURL(_ source: JSONValue?) throws -> String {
        switch source?["type"]?.string {
        case "base64":
            guard let media = source?["media_type"]?.string, let data = source?["data"]?.string else {
                throw ChatParse.bad("base64 image source needs media_type and data.")
            }
            return "data:\(media);base64,\(data)"
        case "url":
            guard let url = source?["url"]?.string else { throw ChatParse.bad("url image source needs url.") }
            return url
        default:
            throw ChatParse.bad("Image source type must be 'base64' or 'url'.")
        }
    }

    // shortcut: tool_choice any/tool is treated as auto (the local model can't be forced to call), upgrade with constrained decoding.
    static func tools(_ body: MessagesRequest) throws -> [ChatTool] {
        if body.tool_choice?["type"]?.string == "none" { return [] }
        return try (body.tools ?? []).map { t in
            if let type = t["type"]?.string, type != "custom" { throw ChatParse.bad("Server tool '\(type)' is not supported.") }
            guard let name = t["name"]?.string else { throw ChatParse.bad("tools: name is required.") }
            let schema = t["input_schema"] ?? .object(["type": .string("object")])
            return ChatTool(name: name, description: t["description"]?.string ?? "", parametersJSON: encodeJSON(schema))
        }
    }
}

func encodeJSON(_ v: JSONValue) -> String {
    (try? JSONEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

// MARK: Wire types

struct AnthropicUsage: Encodable, Sendable {
    var input_tokens: Int
    var output_tokens: Int
    var cache_creation_input_tokens = 0
    var cache_read_input_tokens = 0
}

/// One content block; unused fields are nil and left out of the JSON.
struct AnthropicBlock: Encodable, Sendable {
    var type: String
    var text: String?
    var thinking: String?
    var signature: String?
    var id: String?
    var name: String?
    var input: JSONValue?

    static func text(_ s: String) -> Self { .init(type: "text", text: s) }
    static func thinking(_ s: String) -> Self { .init(type: "thinking", thinking: s, signature: "") }
}

struct AnthropicMessageWire: Encodable, Sendable {
    var id: String
    var type = "message"
    var role = "assistant"
    var model: String
    var content: [AnthropicBlock]
    var stop_reason: JSONValue
    var stop_sequence: JSONValue
    var usage: AnthropicUsage
}

// MARK: Stream assembly

/// Turns chat output into Anthropic content blocks, recording the stream events that build them.
struct MessageAssembler {
    private(set) var blocks: [AnthropicBlock] = []
    private var open: String?   // "text" or "thinking" while that block accepts deltas
    private var pending: [AnyEncodableDict] = []

    var hasToolUse: Bool { blocks.contains { $0.type == "tool_use" } }

    mutating func add(_ kind: String, _ piece: String) {
        var s = piece
        if open != kind {
            s = String(s.drop { $0.isWhitespace })
            guard !s.isEmpty else { return }
            close()
            blocks.append(kind == "text" ? .text("") : .thinking(""))
            open = kind
            event("content_block_start", ["index": blocks.count - 1, "content_block": blocks[blocks.count - 1]])
        }
        guard !s.isEmpty else { return }
        let i = blocks.count - 1
        if kind == "text" {
            blocks[i].text! += s
            event("content_block_delta", ["index": i, "delta": ["type": "text_delta", "text": s]])
        } else {
            blocks[i].thinking! += s
            event("content_block_delta", ["index": i, "delta": ["type": "thinking_delta", "thinking": s]])
        }
    }

    mutating func toolUse(name: String, arguments: String) {
        close()
        let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))) ?? .object([:])
        let id = "toolu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        blocks.append(AnthropicBlock(type: "tool_use", id: id, name: name, input: input))
        let i = blocks.count - 1
        event("content_block_start", ["index": i, "content_block": AnthropicBlock(type: "tool_use", id: id, name: name, input: .object([:]))])
        event("content_block_delta", ["index": i, "delta": ["type": "input_json_delta", "partial_json": encodeJSON(input)]])
        event("content_block_stop", ["index": i])
    }

    mutating func close() {
        guard open != nil else { return }
        let i = blocks.count - 1
        if open == "thinking" { event("content_block_delta", ["index": i, "delta": ["type": "signature_delta", "signature": ""]]) }
        event("content_block_stop", ["index": i])
        open = nil
    }

    mutating func drain() -> [AnyEncodableDict] { defer { pending = [] }; return pending }

    private mutating func event(_ type: String, _ fields: [String: any Encodable & Sendable]) {
        var payload = fields
        payload["type"] = type
        pending.append(AnyEncodableDict(payload))
    }
}

/// With thinking on, Qwen3.5's prompt already ends in `<think>\n`, so output is thinking until `</think>`.
struct ThinkSplitter {
    private var buffer = ""
    private var thinking = true
    private static let end = "</think>"

    mutating func feed(_ s: String) -> (thinking: String, text: String) {
        buffer += s
        guard thinking else { defer { buffer = "" }; return ("", buffer) }
        if buffer.hasPrefix("<think>") { buffer.removeFirst(7) }
        if let r = buffer.range(of: Self.end) {
            thinking = false
            defer { buffer = "" }
            return (String(buffer[..<r.lowerBound]), String(buffer[r.upperBound...]))
        }
        // Hold back a tail that could be the start of `</think>`.
        let keep = (1..<Self.end.count).reversed().first { Self.end.hasPrefix(buffer.suffix($0)) } ?? 0
        let cut = buffer.index(buffer.endIndex, offsetBy: -min(keep, buffer.count))
        defer { buffer = String(buffer[cut...]) }
        return (String(buffer[..<cut]), "")
    }

    mutating func finish() -> (thinking: String, text: String) {
        defer { buffer = "" }
        return thinking ? (buffer, "") : ("", buffer)
    }
}

/// Finds the earliest stop sequence in streamed text, holding back a tail that could still grow into one.
struct StopScanner {
    let stops: [String]
    private var pending = ""

    init(_ stops: [String]) { self.stops = stops.filter { !$0.isEmpty } }

    mutating func feed(_ s: String) -> (text: String, hit: String?) {
        pending += s
        let hits = stops.compactMap { seq in pending.range(of: seq).map { ($0.lowerBound, seq) } }
        if let first = hits.min(by: { $0.0 < $1.0 }) {
            defer { pending = "" }
            return (String(pending[..<first.0]), first.1)
        }
        let keep = max((stops.map(\.count).max() ?? 0) - 1, 0)
        let cut = pending.index(pending.endIndex, offsetBy: -min(keep, pending.count))
        defer { pending = String(pending[cut...]) }
        return (String(pending[..<cut]), nil)
    }

    mutating func finish() -> String { defer { pending = "" }; return pending }
}

// MARK: Routes

func addAnthropicRoutes(to g: RouterGroup<SynapseContext>, chat: ChatService) {
    @Sendable func prepare(_ body: MessagesRequest) async throws -> (ModelSpec, [ChatMessage], ChatOptions) {
        let requested = body.model.flatMap { $0.hasPrefix("claude") ? nil : $0 }
        let spec = try await resolveChat(chat, requested)
        let messages = try await ImageFetcher.messages(try AnthropicParse.messages(body))
        let thinking = ["enabled", "adaptive"].contains(body.thinking?["type"]?.string ?? "")
        var options = ChatOptions(maxTokens: body.max_tokens, temperature: body.temperature, topP: body.top_p, enableThinking: thinking)
        if let k = body.top_k {
            guard k >= 0 else { throw HTTPError(.badRequest, message: "top_k must be 0 or more.") }
            options.topK = k
        }
        options.tools = try AnthropicParse.tools(body)
        return (spec, messages, options)
    }

    g.post("messages/count_tokens") { req, ctx in
        let (spec, messages, options) = try await prepare(try await decodeJSON(MessagesRequest.self, req, ctx))
        return json(["input_tokens": try await chat.countTokens(model: spec, messages: messages, options: options)])
    }

    g.post("messages") { req, ctx in
        let body = try await decodeJSON(MessagesRequest.self, req, ctx)
        let (spec, messages, options) = try await prepare(body)
        let id = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let events = try await chat.stream(model: spec, messages: messages, options: options)
        let stops = body.stop_sequences ?? []

        /// Consumes the generation, reporting each stream event to `emit`, and returns the finished message.
        @Sendable func run(_ emit: (AnyEncodableDict) async throws -> Void) async throws -> AnthropicMessageWire {
            var asm = MessageAssembler()
            var splitter = options.enableThinking ? ThinkSplitter() : nil
            var scanner = StopScanner(stops)
            var stopReason = "end_turn", stopSequence: String?
            var usage = AnthropicUsage(input_tokens: 0, output_tokens: 0)
            var chunks = 0
            func text(_ pieces: (thinking: String, text: String), final: Bool) {
                asm.add("thinking", pieces.thinking)
                let (out, hit) = scanner.feed(pieces.text)
                asm.add("text", out + (final && hit == nil ? scanner.finish() : ""))
                if let hit { stopReason = "stop_sequence"; stopSequence = hit }
            }
            loop: for try await e in events {
                switch e {
                case .delta(let s):
                    chunks += 1
                    text(splitter?.feed(s) ?? ("", s), final: false)
                    // shortcut: on a stop sequence generation is cut before its usage report, so output_tokens counts chunks and input_tokens is 0.
                    if stopSequence != nil { usage.output_tokens = chunks }
                case .toolCall(let name, let arguments):
                    asm.toolUse(name: name, arguments: arguments)
                case .progress: break
                case .done(let finish, let u):
                    text(splitter?.finish() ?? ("", ""), final: true)
                    // Anthropic counts cache reads apart from input_tokens; caching here is automatic, so there are no cache writes.
                    usage = AnthropicUsage(input_tokens: u.promptTokens - u.cachedTokens, output_tokens: u.completionTokens,
                                           cache_read_input_tokens: u.cachedTokens)
                    if stopSequence == nil {
                        stopReason = asm.hasToolUse ? "tool_use" : finish == "length" ? "max_tokens" : "end_turn"
                    }
                }
                for event in asm.drain() { try await emit(event) }
                if stopSequence != nil { break loop }
            }
            asm.close()
            for event in asm.drain() { try await emit(event) }
            return AnthropicMessageWire(id: id, model: spec.id, content: asm.blocks, stop_reason: .string(stopReason),
                                        stop_sequence: stopSequence.map(JSONValue.string) ?? .null, usage: usage)
        }

        guard body.stream == true else { return json(try await run { _ in }) }
        return sse { write in
            let start = AnthropicMessageWire(id: id, model: spec.id, content: [], stop_reason: .null, stop_sequence: .null,
                                             usage: AnthropicUsage(input_tokens: 0, output_tokens: 0))
            try await write("message_start", AnyEncodableDict(["type": "message_start", "message": start]))
            let final = try await run { event in
                try await write((event.values["type"] as? String) ?? "", event)
            }
            try await write("message_delta", AnyEncodableDict([
                "type": "message_delta", "usage": final.usage,
                "delta": AnyEncodableDict(["stop_reason": final.stop_reason, "stop_sequence": final.stop_sequence]),
            ]))
            try await write("message_stop", AnyEncodableDict(["type": "message_stop"]))
        }
    }
}
