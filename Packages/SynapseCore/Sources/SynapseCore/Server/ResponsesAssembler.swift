import Foundation

// Builds a Responses `output` list from chat and built-in tool events, recording the stream events that build it.
// Items appear in the order they happen (reasoning, tool calls, message text, as often as the model alternates);
// the client's function calls follow at the end.

struct WebSearchCallWire: Encodable, Sendable {
    struct Source: Encodable, Sendable { var type = "url"; var url: String }
    /// OpenAI's `search` (query, sources) or `open_page` (url) action.
    struct Action: Encodable, Sendable { var type = "search"; var query: String?; var url: String?; var sources: [Source]? }
    var type = "web_search_call"
    var id: String
    var status: String
    var action: Action
}

/// Synapse's own tools as an output item (not an OpenAI type; SDKs keep unknown items as they are).
struct SynapseToolCallWire: Encodable, Sendable {
    var type = "synapse_tool_call"
    var id: String
    var status: String
    var name: String
    var arguments: String
    var output: String?
    /// The audio file, or where the video will be once rendered (generate_speech, generate_sound, generate_video).
    var url: String? = nil
}

extension ServerToolCall {
    func responsesItem(running: Bool) -> ResponseOutputItemWire {
        let status = running ? "in_progress" : error == nil ? "completed" : "failed"
        switch kind {
        case .webSearch:
            var sources: [WebSearchCallWire.Source]?
            if case .search(_, let results)? = output { sources = results.map { .init(url: $0.url) } }
            return .webSearch(.init(id: id, status: status, action: .init(query: query, sources: sources)))
        case .webFetch:
            var url = argumentsObject["url"]?.string
            if case .page(let p)? = output { url = p.url }
            return .webSearch(.init(id: id, status: status, action: .init(type: "open_page", query: nil, url: url)))
        case .image:
            var image: GeneratedImage?
            if case .image(let g)? = output { image = g }
            return .image(ImageGenerationCallWire(id: id, status: status, result: image?.data.base64EncodedString(),
                                                  revised_prompt: image?.prompt ?? argumentsObject["prompt"]?.string, action: image?.action,
                                                  output_format: image?.format ?? "png", size: image?.size ?? "auto", quality: image?.quality ?? "auto"))
        case .time, .dates, .calculate, .models, .status, .speech, .sound, .video:
            var url: String?
            if case .media(let m)? = output { url = m.url }
            return .synapseTool(.init(id: id, status: status, name: kind.rawValue, arguments: arguments,
                                      output: running ? nil : error.map { "Error: \($0)" } ?? forModel, url: url))
        }
    }

    /// The `response.<item type>` prefix of this call's own events.
    var responsesEventPrefix: String {
        switch kind {
        case .webSearch, .webFetch: "response.web_search_call"
        case .image: "response.image_generation_call"
        case .time, .dates, .calculate, .models, .status, .speech, .sound, .video: "response.synapse_tool_call"
        }
    }
}

struct ResponsesAssembler {
    typealias Event = (type: String, fields: [String: any Encodable & Sendable])

    private(set) var items: [ResponseOutputItemWire] = []
    /// All message text, as `output_text`.
    private(set) var text = ""
    private var open: (kind: Kind, index: Int, id: String, text: String)?
    private var calls: [FunctionCallWire] = []
    private var pending: [Event] = []

    enum Kind { case reasoning, message }

    var hasFunctionCalls: Bool { !calls.isEmpty }

    mutating func reasoning(_ s: String) {
        guard !s.isEmpty else { return }
        let i = begin(.reasoning)
        open!.text += s
        event("response.reasoning_text.delta", ["item_id": open!.id, "output_index": i, "content_index": 0, "delta": s])
    }

    mutating func text(_ piece: String) {
        let s = open?.kind == .message ? piece : String(piece.drop { $0.isWhitespace })
        guard !s.isEmpty else { return }
        let i = begin(.message)
        open!.text += s
        text += s
        event("response.output_text.delta", ["item_id": open!.id, "output_index": i, "content_index": 0, "delta": s, "logprobs": [String]()])
    }

    mutating func functionCall(name: String, arguments: String) {
        calls.append(FunctionCallWire(name: name, arguments: arguments))
    }

    mutating func toolStarted(_ call: ServerToolCall) {
        close()
        items.append(call.responsesItem(running: true))
        let i = items.count - 1
        event("response.output_item.added", ["output_index": i, "item": items[i]])
        event(call.responsesEventPrefix + ".in_progress", ["item_id": call.id, "output_index": i])
        switch call.kind {
        case .webSearch, .webFetch: event("response.web_search_call.searching", ["item_id": call.id, "output_index": i])
        case .image: event("response.image_generation_call.generating", ["item_id": call.id, "output_index": i])
        case .time, .dates, .calculate, .models, .status, .speech, .sound, .video: break
        }
    }

    mutating func toolFinished(_ call: ServerToolCall) {
        guard let i = items.lastIndex(where: { $0.id == call.id }) else { return }
        items[i] = call.responsesItem(running: false)
        event(call.responsesEventPrefix + (call.error == nil ? ".completed" : ".failed"), ["item_id": call.id, "output_index": i])
        event("response.output_item.done", ["output_index": i, "item": items[i]])
    }

    /// Ends the output. A message item is always there when streaming (it was announced), otherwise only when there
    /// is text or nothing else to show; the client's function calls come last.
    mutating func finish(messageStatus: String, alwaysMessage: Bool) {
        let hasMessage = items.contains { if case .message = $0 { true } else { false } } || open?.kind == .message
        if !hasMessage && (alwaysMessage || (calls.isEmpty && !items.contains { $0.isToolCall })) { _ = begin(.message) }
        close(messageStatus: messageStatus)
        for call in calls {
            items.append(.functionCall(call))
            let i = items.count - 1
            event("response.output_item.added", ["output_index": i, "item": call.with(status: "in_progress", arguments: "")])
            event("response.function_call_arguments.delta", ["item_id": call.id, "output_index": i, "delta": call.arguments])
            event("response.function_call_arguments.done", ["item_id": call.id, "output_index": i, "name": call.name, "arguments": call.arguments])
            event("response.output_item.done", ["output_index": i, "item": call])
        }
        calls = []
    }

    mutating func drain() -> [Event] { defer { pending = [] }; return pending }

    private mutating func begin(_ kind: Kind) -> Int {
        if let open, open.kind == kind { return open.index }
        close()
        let id = (kind == .reasoning ? "rs_" : "msg_") + newServerToolID()
        let i = items.count
        switch kind {
        case .reasoning:
            items.append(.reasoning(.init(id: id, status: "in_progress", content: [])))
            event("response.output_item.added", ["output_index": i, "item": items[i]])
            event("response.content_part.added", ["item_id": id, "output_index": i, "content_index": 0, "part": ReasoningTextPart(text: "")])
        case .message:
            items.append(.message(.init(id: id, status: "in_progress", content: [])))
            event("response.output_item.added", ["output_index": i, "item": items[i]])
            event("response.content_part.added", ["item_id": id, "output_index": i, "content_index": 0, "part": OutputTextPart(text: "")])
        }
        open = (kind, i, id, "")
        return i
    }

    private mutating func close(messageStatus: String = "completed") {
        guard let o = open else { return }
        open = nil
        switch o.kind {
        case .reasoning:
            items[o.index] = .reasoning(.init(id: o.id, content: [.init(text: o.text)]))
            event("response.reasoning_text.done", ["item_id": o.id, "output_index": o.index, "content_index": 0, "text": o.text])
            event("response.content_part.done", ["item_id": o.id, "output_index": o.index, "content_index": 0, "part": ReasoningTextPart(text: o.text)])
        case .message:
            items[o.index] = .message(.init(id: o.id, status: messageStatus, content: [.init(text: o.text)]))
            event("response.output_text.done", ["item_id": o.id, "output_index": o.index, "content_index": 0, "text": o.text, "logprobs": [String]()])
            event("response.content_part.done", ["item_id": o.id, "output_index": o.index, "content_index": 0, "part": OutputTextPart(text: o.text)])
        }
        event("response.output_item.done", ["output_index": o.index, "item": items[o.index]])
    }

    private mutating func event(_ type: String, _ fields: [String: any Encodable & Sendable]) {
        pending.append((type, fields))
    }
}

extension ResponseOutputItemWire {
    var id: String {
        switch self {
        case .message(let m): m.id
        case .image(let i): i.id
        case .functionCall(let f): f.id
        case .reasoning(let r): r.id
        case .webSearch(let w): w.id
        case .synapseTool(let s): s.id
        }
    }

    var isToolCall: Bool {
        switch self {
        case .image, .webSearch, .synapseTool: true
        case .message, .functionCall, .reasoning: false
        }
    }
}
