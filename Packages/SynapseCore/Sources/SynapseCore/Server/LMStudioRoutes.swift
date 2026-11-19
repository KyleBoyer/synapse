import Foundation
import Hummingbird

/// LM Studio's native chat API (`POST /api/v1/chat`): one input per request, the conversation carried by
/// `previous_response_id`, and a stream of named events that reports model load and prompt processing before the
/// answer. Shapes follow https://lmstudio.ai/docs/developer/rest/chat and .../streaming-events.
struct LMStudioChatRequest: Decodable {
    var model: String?
    var input: JSONValue
    var system_prompt: String?
    var stream: Bool?
    var temperature: Float?
    var top_p: Float?
    var max_output_tokens: Int?
    /// "off" turns reasoning off; any other setting turns it on. Absent: off, as on Synapse's other routes.
    var reasoning: JSONValue?
    var store: Bool?
    var previous_response_id: String?
    var integrations: JSONValue?
}

/// Conversations kept for `previous_response_id`, newest last.
// shortcut: in memory and capped, so a restart or the 257th conversation forgets the oldest; persist if clients need it.
actor LMStudioConversations {
    private var items: [String: [ChatMessage]] = [:]
    private var order: [String] = []
    private let cap = 256

    func get(_ id: String) -> [ChatMessage]? { items[id] }

    func put(_ id: String, _ messages: [ChatMessage]) {
        items[id] = messages
        order.append(id)
        if order.count > cap { items[order.removeFirst()] = nil }
    }
}

func addLMStudioRoutes(to g: RouterGroup<SynapseContext>, chat: ChatService, conversations: LMStudioConversations) {
    g.post("api/v1/chat") { req, ctx in
        let raw = try await rawBody(req, ctx)
        let body = try decodeJSON(LMStudioChatRequest.self, raw)
        let sampling = try SamplingFields.read(raw)
        if let i = body.integrations, i.array?.isEmpty != true {
            throw HTTPError(.badRequest, message: "Synapse runs models only: integrations (plugins, MCP servers) are not supported.")
        }
        let spec = try await resolveChat(chat, body.model)
        var history: [ChatMessage] = []
        if let prev = body.previous_response_id {
            guard let h = await conversations.get(prev) else {
                throw HTTPError(.badRequest, message: "Unknown previous_response_id '\(prev)'.")
            }
            history = h
        } else if let s = body.system_prompt, !s.isEmpty {
            history = [ChatMessage(role: .system, text: s)]
        }
        let input = try await ImageFetcher.messages([(.user, try LMStudioParse.input(body.input))])
        try await requireMediaSupport(chat, spec, input)
        let messages = history + input
        let thinking = body.reasoning.map { $0.string != "off" && $0.bool != false } ?? false
        var options = ChatOptions(maxTokens: body.max_output_tokens, temperature: body.temperature, topP: body.top_p,
                                  enableThinking: thinking)
        sampling.apply(to: &options)
        let responseID = body.store == false ? nil
            : "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let events = try await chat.stream(model: spec, messages: messages, options: options)

        @Sendable func save(_ run: LMStudioRun) async {
            guard let responseID else { return }
            await conversations.put(responseID, messages + [ChatMessage(role: .assistant, text: run.message)])
        }
        guard body.stream == true else {
            var run = LMStudioRun(model: spec.id, thinking: thinking, responseID: responseID)
            for try await e in events { _ = run.consume(e) }
            await save(run)
            return json(run.result())
        }
        return sse { write in
            var run = LMStudioRun(model: spec.id, thinking: thinking, responseID: responseID)
            func emit(_ events: [LMStudioRun.Event]) async throws {
                for (type, fields) in events {
                    var payload = fields
                    payload["type"] = type
                    try await write(type, AnyEncodableDict(payload))
                }
            }
            try await emit([("chat.start", ["model_instance_id": spec.id])])
            do {
                for try await e in events { try await emit(run.consume(e)) }
                try await emit(run.close())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // LM Studio still sends chat.end, with whatever was generated, after an error event.
                try await emit(run.close() + [("error", ["error": AnyEncodableDict(["type": "server_error", "message": error.localizedDescription])])])
            }
            await save(run)
            try await emit([("chat.end", ["result": run.result()])])
        }
    }
}

enum LMStudioParse {
    /// `input` is a string, or an array of `{"type":"text","content":…}` and `{"type":"image","data_url":…}`.
    static func input(_ v: JSONValue) throws -> [ContentPart] {
        if let s = v.string { return [.text(s)] }
        guard let items = v.array, !items.isEmpty else { throw HTTPError(.badRequest, message: "input must be a string or a non-empty array.") }
        return try items.map { item in
            switch item["type"]?.string {
            case "text":
                guard let t = item["content"]?.string else { throw HTTPError(.badRequest, message: "A text input needs content.") }
                return .text(t)
            case "image":
                guard let u = item["data_url"]?.string else { throw HTTPError(.badRequest, message: "An image input needs data_url.") }
                return .image(u)
            default:
                throw HTTPError(.badRequest, message: "Unsupported input type '\(item["type"]?.string ?? "")'; use text or image.")
            }
        }
    }
}

/// One response as it streams: turns `ChatEvent`s into LM Studio events and builds the final result with its stats.
struct LMStudioRun {
    typealias Event = (String, [String: any Encodable & Sendable])
    let model: String
    let responseID: String?
    private var splitter: ThinkSplitter?
    private(set) var reasoning = "", message = ""
    private var open: String?          // "reasoning" or "message" while that block streams
    private var reasoningChunks = 0
    private var usage = ChatUsage(promptTokens: 0, completionTokens: 0)
    private var loadSeconds: Double?
    private var promptStart = ContinuousClock.now
    private var firstToken: ContinuousClock.Instant?
    private var lastToken: ContinuousClock.Instant?

    init(model: String, thinking: Bool, responseID: String?) {
        self.model = model; self.responseID = responseID
        splitter = thinking ? ThinkSplitter() : nil
    }

    mutating func consume(_ e: ChatEvent) -> [Event] {
        switch e {
        case .progress(.loadStarted): return [("model_load.start", ["model_instance_id": model])]
        case .progress(.loaded(let s)):
            loadSeconds = s
            return [("model_load.end", ["model_instance_id": model, "load_time_seconds": s])]
        case .progress(.promptStarted):
            promptStart = .now
            return [("prompt_processing.start", [:])]
        case .progress(.prompt(let f)): return [("prompt_processing.progress", ["progress": min(max(f, 0), 1)])]
        case .progress(.promptDone): return [("prompt_processing.end", [:])]
        case .delta(let s):
            let now = ContinuousClock.now
            firstToken = firstToken ?? now
            lastToken = now
            let (r, t) = splitter?.feed(s) ?? ("", s)
            if !r.isEmpty { reasoningChunks += 1 }
            return text(r, t)
        case .toolCall: return []
        case .done(_, let u):
            usage = u
            return []
        }
    }

    /// Flushes held-back text and closes the open block.
    mutating func close() -> [Event] {
        let (r, t) = splitter?.finish() ?? ("", "")
        var out = text(r, t)
        if let o = open { out.append(("\(o).end", [:])); open = nil }
        return out
    }

    private mutating func text(_ r: String, _ t: String) -> [Event] {
        var out: [Event] = []
        for (kind, piece) in [("reasoning", r), ("message", t)] where !piece.isEmpty {
            if open != kind {
                if let o = open { out.append(("\(o).end", [:])) }
                out.append(("\(kind).start", [:]))
                open = kind
            }
            if kind == "reasoning" { reasoning += piece } else { message += piece }
            out.append(("\(kind).delta", ["content": piece]))
        }
        return out
    }

    func result() -> AnyEncodableDict {
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        var output: [AnyEncodableDict] = []
        if !reasoning.isEmpty { output.append(AnyEncodableDict(["type": "reasoning", "content": reasoning])) }
        output.append(AnyEncodableDict(["type": "message", "content": message]))
        let decode = firstToken.flatMap { f in lastToken.map { seconds($0 - f) } } ?? 0
        var stats: [String: any Encodable & Sendable] = [
            "input_tokens": usage.promptTokens,
            "cached_tokens": usage.cachedTokens,
            "total_output_tokens": usage.completionTokens,
            // shortcut: one streamed chunk is about one token, so reasoning tokens are counted in chunks.
            "reasoning_output_tokens": min(reasoningChunks, usage.completionTokens),
            "tokens_per_second": decode > 0 ? Double(max(usage.completionTokens - 1, 0)) / decode : 0,
            "time_to_first_token_seconds": firstToken.map { seconds($0 - promptStart) } ?? 0,
        ]
        if let loadSeconds { stats["model_load_time_seconds"] = loadSeconds }
        var r: [String: any Encodable & Sendable] = ["model_instance_id": model, "output": output, "stats": AnyEncodableDict(stats)]
        if let responseID { r["response_id"] = responseID }
        return AnyEncodableDict(r)
    }
}
