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
            case "server_tool_use":
                // A built-in tool's earlier turn, sent back: the call and its result go to the model as tool markup.
                guard case .object(let input) = b["input"] ?? .object([:]) else { return [] }
                return [.text(ToolMarkup.call(name: b["name"]?.string ?? "", arguments: input))]
            case "web_search_tool_result":
                let results = (b["content"]?.array ?? []).map { "\($0["title"]?.string ?? "")\n\($0["url"]?.string ?? "")" }
                return [.text(ToolMarkup.response(results.joined(separator: "\n\n")))]
            case "web_fetch_tool_result":
                let c = b["content"]
                let text = c?["content"]?["source"]?["data"]?.string ?? ""
                return [.text(ToolMarkup.response("\(c?["url"]?.string ?? "")\n\n\(text)"))]
            case "synapse_tool_result":
                let text = (b["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                return [.text(ToolMarkup.response(text))]
            case "image_generation_tool_result":
                return [.text(ToolMarkup.response("The image was created and shown to the user."))]
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
    /// Server tools Synapse runs (web_search_*, image_generation, synapse) and the client's custom tools.
    static func tools(_ body: MessagesRequest, settings: ToolSettings = ToolSettings()) throws -> (ServerTools, [ChatTool]) {
        if body.tool_choice?["type"]?.string == "none" { return (ServerTools(), []) }
        let (server, rest) = try ServerTools.split(body.tools, settings: settings)
        return (server, try rest.map { t in
            if let type = t["type"]?.string, type != "custom" { throw ChatParse.bad("Server tool '\(type)' is not supported.") }
            guard let name = t["name"]?.string else { throw ChatParse.bad("tools: name is required.") }
            let schema = t["input_schema"] ?? .object(["type": .string("object")])
            return ChatTool(name: name, description: t["description"]?.string ?? "", parametersJSON: encodeJSON(schema))
        })
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
    var server_tool_use: [String: Int]? = nil
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
    var tool_use_id: String?
    var content: JSONValue?

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

    /// A built-in tool starting: Anthropic's server_tool_use block.
    mutating func serverToolUse(_ call: ServerToolCall) {
        close()
        let input = JSONValue.object(call.argumentsObject)
        blocks.append(AnthropicBlock(type: "server_tool_use", id: call.anthropicID, name: call.kind.rawValue, input: input))
        let i = blocks.count - 1
        event("content_block_start", ["index": i, "content_block": AnthropicBlock(type: "server_tool_use", id: call.anthropicID,
                                                                                  name: call.kind.rawValue, input: .object([:]))])
        event("content_block_delta", ["index": i, "delta": ["type": "input_json_delta", "partial_json": encodeJSON(input)]])
        event("content_block_stop", ["index": i])
    }

    /// Its result: web_search_tool_result as Anthropic's, image_generation_tool_result and synapse_tool_result as Synapse's own.
    mutating func serverToolResult(_ call: ServerToolCall) {
        close()
        let content: JSONValue
        let type: String
        switch call.kind {
        case .webSearch:
            type = "web_search_tool_result"
            if case .search(_, let results)? = call.output {
                content = .array(results.map { .object(["type": .string("web_search_result"), "url": .string($0.url), "title": .string($0.title),
                                                        "encrypted_content": .string(""), "page_age": .null]) })
            } else {
                content = .object(["type": .string("web_search_tool_result_error"), "error_code": .string("unavailable")])
            }
        case .webFetch:
            type = "web_fetch_tool_result"
            if case .page(let p)? = call.output {
                content = .object(["type": .string("web_fetch_result"), "url": .string(p.url), "retrieved_at": .string(ISO8601DateFormatter().string(from: Date())),
                                   "content": .object(["type": .string("document"), "title": .string(p.title), "source": .object([
                                       "type": .string("text"), "media_type": .string("text/plain"), "data": .string(p.text)])])])
            } else {
                content = .object(["type": .string("web_fetch_tool_error"), "error_code": .string("unavailable")])
            }
        case .image:
            type = "image_generation_tool_result"
            if case .image(let g)? = call.output {
                content = .array([.object(["type": .string("image"), "source": .object([
                    "type": .string("base64"), "media_type": .string(g.format == "jpeg" ? "image/jpeg" : "image/\(g.format)"),
                    "data": .string(g.data.base64EncodedString())])])])
            } else {
                content = .array([.object(["type": .string("text"), "text": .string(call.forModel)])])
            }
        case .time, .dates, .calculate, .models, .status, .speech, .sound, .video:
            type = "synapse_tool_result"
            var text = call.forModel
            if case .media(let m)? = call.output { text = m.url + "\n" + text }
            content = .array([.object(["type": .string("text"), "text": .string(text)])])
        }
        blocks.append(AnthropicBlock(type: type, tool_use_id: call.anthropicID, content: content))
        let i = blocks.count - 1
        event("content_block_start", ["index": i, "content_block": blocks[i]])
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

extension ServerToolCall {
    var anthropicID: String { "srvtoolu_" + id }
}

func addAnthropicRoutes(to g: RouterGroup<SynapseContext>, chat: ChatService, tools backends: ToolBackends, settings: SettingsBox) {
    @Sendable func prepare(_ body: MessagesRequest) async throws -> (ModelSpec, [ChatMessage], ChatOptions, ServerTools) {
        let requested = body.model.flatMap { $0.hasPrefix("claude") ? nil : $0 }
        let spec = try await resolveChat(chat, requested)
        let messages = try await ImageFetcher.messages(try AnthropicParse.messages(body))
        let thinking = ["enabled", "adaptive"].contains(body.thinking?["type"]?.string ?? "")
        var options = ChatOptions(maxTokens: body.max_tokens, temperature: body.temperature, topP: body.top_p, enableThinking: thinking)
        if body.thinking?["type"]?.string == "enabled" { options.thinkingBudget = body.thinking?["budget_tokens"]?.number.map { Int($0) } }
        if let k = body.top_k {
            guard k >= 0 else { throw HTTPError(.badRequest, message: "top_k must be 0 or more.") }
            options.topK = k
        }
        let (server, tools) = try AnthropicParse.tools(body, settings: settings.current.tools)
        options.tools = tools
        return (spec, messages, options, server)
    }

    g.post("messages/count_tokens") { req, ctx in
        var (spec, messages, options, server) = try await prepare(try await decodeJSON(MessagesRequest.self, req, ctx))
        options.tools = server.functions + options.tools
        return json(["input_tokens": try await chat.countTokens(model: spec, messages: messages, options: options)])
    }

    g.post("messages") { req, ctx in
        let body = try await decodeJSON(MessagesRequest.self, req, ctx)
        let (spec, messages, options, server) = try await prepare(body)
        let id = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let services = backends.services(req, ctx, server)
        let events = try await chatWithServerTools(server, services: services, spec: spec, messages: messages, options: options)
        let stops = body.stop_sequences ?? []

        /// Consumes the generation, reporting each stream event to `emit`, and returns the finished message.
        @Sendable func run(_ emit: (AnyEncodableDict) async throws -> Void) async throws -> AnthropicMessageWire {
            var asm = MessageAssembler()
            var scanner = StopScanner(stops)
            var stopReason = "end_turn", stopSequence: String?
            var usage = AnthropicUsage(input_tokens: 0, output_tokens: 0)
            var chunks = 0, searches = 0
            func text(_ piece: String, final: Bool) {
                let (out, hit) = scanner.feed(piece)
                asm.add("text", out + (final && hit == nil ? scanner.finish() : ""))
                if let hit { stopReason = "stop_sequence"; stopSequence = hit }
            }
            loop: for try await e in events {
                switch e {
                case .chat(.delta(let s)):
                    chunks += 1
                    text(s, final: false)
                    // shortcut: on a stop sequence generation is cut before its usage report, so output_tokens counts chunks and input_tokens is 0.
                    if stopSequence != nil { usage.output_tokens = chunks }
                case .chat(.toolCall(let name, let arguments)):
                    asm.toolUse(name: name, arguments: arguments)
                case .chat(.reasoning(let r)):
                    asm.add("thinking", r)
                case .chat(.progress(let p)):
                    // Not an Anthropic event; clients skip unknown event types, and this shows load and prompt reading.
                    try await emit(p.wire(type: "synapse_progress"))
                case .toolStarted(let call):
                    asm.serverToolUse(call)
                    if call.kind == .webSearch { searches += 1 }
                case .toolFinished(let call):
                    asm.serverToolResult(call)
                case .chat(.done(let finish, let u)):
                    text("", final: true)
                    // Anthropic counts cache reads apart from input_tokens; caching here is automatic, so there are no cache writes.
                    usage = AnthropicUsage(input_tokens: u.promptTokens - u.cachedTokens, output_tokens: u.completionTokens,
                                           cache_read_input_tokens: u.cachedTokens,
                                           server_tool_use: server.webSearch ? ["web_search_requests": searches] : nil)
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
