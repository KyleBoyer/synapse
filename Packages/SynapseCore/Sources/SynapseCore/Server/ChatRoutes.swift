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

/// Sampling fields beyond temperature and top_p, read from any chat request body. `top_k`, `min_p` and
/// `repetition_penalty` are extensions OpenAI does not define (llama.cpp and vLLM take the same names);
/// `repeat_penalty` is LM Studio's spelling.
struct SamplingFields: Decodable {
    var seed: Int64?, top_k: Int?, min_p: Float?
    var presence_penalty: Float?, frequency_penalty: Float?, repetition_penalty: Float?, repeat_penalty: Float?

    /// Decodes and validates, so a bad value is a 400 before any model work.
    static func read(_ raw: Data) throws -> SamplingFields {
        let f = try decodeJSON(SamplingFields.self, raw)
        try f.validate()
        return f
    }

    private func validate() throws {
        func bad(_ m: String) -> HTTPError { HTTPError(.badRequest, message: m) }
        for (name, v) in [("presence_penalty", presence_penalty), ("frequency_penalty", frequency_penalty)] {
            if let v, !(-2...2).contains(v) { throw bad("\(name) must be between -2 and 2.") }
        }
        let repetition = repetition_penalty ?? repeat_penalty
        if let r = repetition, r <= 0 { throw bad("repetition_penalty must be greater than 0.") }
        if let k = top_k, k < 0 { throw bad("top_k must be 0 or more.") }
        if let p = min_p, !(0...1).contains(p) { throw bad("min_p must be between 0 and 1.") }
    }

    func apply(to o: inout ChatOptions) {
        let repetition = repetition_penalty ?? repeat_penalty
        o.seed = seed.map { UInt64(bitPattern: $0) }
        o.topK = top_k; o.minP = min_p
        o.presencePenalty = presence_penalty; o.frequencyPenalty = frequency_penalty; o.repetitionPenalty = repetition
    }
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
    var stop: JSONValue?
    var reasoning_effort: String?
    /// `["text", "audio"]` asks for a spoken reply; `audio` carries `format` and `voice`.
    var modalities: [String]?
    var audio: JSONValue?
    var tools: [JSONValue]?
    var tool_choice: JSONValue?
    var web_search_options: JSONValue?
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
    case video(String)   // data: URL or http(s) URL
    case audio(data: String, format: String)   // OpenAI input_audio: base64 and a format name
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
            case "video_url", "input_video":
                let url = item["video_url"]?.string ?? item["video_url"]?["url"]?.string
                guard let url else { throw bad("Video part is missing video_url.") }
                return .video(url)
            case "input_audio":
                guard let data = item["input_audio"]?["data"]?.string else { throw bad("input_audio part is missing input_audio.data.") }
                return .audio(data: data, format: item["input_audio"]?["format"]?.string ?? "wav")
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

    /// Chat Completions messages, with tool history: an assistant's `tool_calls` and `tool` results are kept as the
    /// markup the models write calls in (ToolMarkup).
    static func chatMessages(_ raw: [JSONValue]) throws -> [(ChatMessage.Role, [ContentPart])] {
        try raw.map { m in
            if m["role"]?.string == "tool" {
                let text = try parts(m["content"]).compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
                return (.user, [.text(ToolMarkup.response(text))])
            }
            var p = try parts(m["content"])
            for call in m["tool_calls"]?.array ?? [] {
                guard let name = call["function"]?["name"]?.string else { throw bad("tool_calls entries need function.name.") }
                p.append(.text(ToolMarkup.call(name: name, argumentsJSON: call["function"]?["arguments"]?.string ?? "{}")))
            }
            return (try role(m["role"]?.string), p)
        }
    }

    /// Function tools in Chat Completions form ({type, function: {name, description, parameters}}) or Responses form
    /// ({type, name, description, parameters}); tool_choice "none" turns them off.
    // shortcut: "required" and a named function are treated as auto (a local model can't be forced to call).
    static func functionTools(_ tools: [JSONValue]?, choice: JSONValue?) throws -> [ChatTool] {
        if choice?.string == "none" { return [] }
        return try (tools ?? []).map { t in
            guard (t["type"]?.string ?? "function") == "function" else {
                throw bad("Unsupported tool type '\(t["type"]?.string ?? "")'; only function tools are supported here.")
            }
            let fn = t["function"] ?? t
            guard let name = fn["name"]?.string else { throw bad("Every tool needs a function name.") }
            return ChatTool(name: name, description: fn["description"]?.string ?? "",
                            parametersJSON: fn["parameters"].map(encodeJSON) ?? #"{"type":"object","properties":{}}"#)
        }
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
            } else if item["type"]?.string == "function_call" {
                guard let name = item["name"]?.string else { throw bad("function_call items need name.") }
                out.append((.assistant, [.text(ToolMarkup.call(name: name, argumentsJSON: item["arguments"]?.string ?? "{}"))]))
            } else if item["type"]?.string == "function_call_output" {
                let output = item["output"]?.string ?? item["output"].map(encodeJSON) ?? ""
                out.append((.user, [.text(ToolMarkup.response(output))]))
            } else if let type = item["type"]?.string,
                      ["reasoning", "web_search_call", "image_generation_call", "synapse_tool_call"].contains(type) {
                // Output items sent back with the history; Synapse ran these itself, and the answer that used them follows.
                continue
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
            var videos: [URL] = []
            var audios: [URL] = []
            for p in parts {
                switch p {
                case .text(let t): text.append(t)
                case .image(let u): images.append(try await load(u))
                case .video(let u): videos.append(try await MediaFiles.loadVideo(u))
                case .audio(let data, let format): audios.append(try await MediaFiles.loadAudio(base64: data, format: format))
                }
            }
            out.append(ChatMessage(role: role, text: text.joined(separator: "\n"), images: images, videos: videos, audios: audios))
        }
        return out
    }
}

// MARK: Wire types (encoding)

struct ChatUsageWire: Encodable {
    var prompt_tokens: Int, completion_tokens: Int, total_tokens: Int
    var prompt_tokens_details: [String: Int]
    init(_ u: ChatUsage) {
        prompt_tokens = u.promptTokens; completion_tokens = u.completionTokens; total_tokens = u.totalTokens
        prompt_tokens_details = ["cached_tokens": u.cachedTokens]
    }
}

struct ChatCompletionWire: Encodable {
    struct Choice: Encodable {
        struct Message: Encodable {
            var role = "assistant"; var content: String?; var refusal: String? = nil
            var audio: ChatAudioWire? = nil
            var tool_calls: [ToolCallWire]? = nil
            /// DeepSeek's and llama.cpp's field for thinking, which most OpenAI-style clients read.
            var reasoning_content: String? = nil
            /// Synapse's own: the built-in tools that ran for this answer.
            var synapse_tool_calls: [SynapseToolWire]? = nil
        }
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

/// A Chat Completions tool call; `index` is set in streamed deltas only.
struct ToolCallWire: Encodable {
    struct Function: Encodable { var name: String; var arguments: String }
    var index: Int? = nil
    var id: String
    var type = "function"
    var function: Function

    static func newID() -> String { "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased() }
    init(index: Int? = nil, name: String, arguments: String) {
        self.index = index; id = Self.newID(); function = Function(name: name, arguments: arguments)
    }
}

struct ChatChunkWire: Encodable {
    struct Choice: Encodable {
        struct Delta: Encodable {
            var role: String?; var content: String?; var audio: ChatAudioDeltaWire? = nil
            var tool_calls: [ToolCallWire]? = nil
            /// DeepSeek's and llama.cpp's field for thinking, which most OpenAI-style clients read.
            var reasoning_content: String? = nil
        }
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
    /// Synapse's own: load and prompt-reading phases before the first token, as `ChatProgress.wire`.
    var synapse_progress: AnyEncodableDict? = nil
    /// Synapse's own: a built-in tool starting (status in_progress) or finished.
    var synapse_tool_call: SynapseToolWire? = nil
}

/// A built-in tool call on Chat Completions, which has no item for one.
struct SynapseToolWire: Encodable, Sendable {
    var id: String
    var name: String
    var status: String
    var arguments: String
    /// What the model read back (search results, Synapse info), or the image URL.
    var output: String?

    init(_ call: ServerToolCall, running: Bool) {
        id = call.id; name = call.kind.rawValue; arguments = call.arguments
        status = running ? "in_progress" : call.error == nil ? "completed" : "failed"
        if !running {
            switch call.output {
            case .image(let g)?: output = g.url
            case .media(let m)?: output = m.url
            default: output = call.forModel
            }
        }
    }
}

extension ServerToolCall {
    /// Text added to a Chat Completions answer so chat apps show the result: a generated image as a markdown image.
    var markdown: String {
        func label(_ s: String) -> String { String(s.prefix(80)).replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ") }
        switch output {
        case .image(let g)?: if let url = g.url { return "\n\n![\(label(g.prompt))](\(url))\n\n" }
        case .media(let m)? where m.kind == .video: return "\n\n[Video (rendering; it can take up to an hour): \(label(m.prompt))](\(m.url))\n\n"
        case .media(let m)?: return "\n\n[Listen: \(label(m.prompt))](\(m.url))\n\n"
        default: break
        }
        return ""
    }
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
        init(_ u: ChatUsage) {
            input_tokens = u.promptTokens; output_tokens = u.completionTokens; total_tokens = u.totalTokens
            input_tokens_details["cached_tokens"] = u.cachedTokens
        }
    }
    struct Incomplete: Encodable { var reason: String }
    var id: String
    var object = "response"
    var created_at: Int
    var status: String
    var model: String
    var output: [ResponseOutputItemWire]
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

/// Chat Completions with a spoken reply: `message.audio` whole, or `delta.audio` pieces (pcm16) when streaming.
private func audioReply(_ p: ChatAudio.Params, id: String, created: Int, spec: ModelSpec, messages: [ChatMessage],
                        options: ChatOptions, stream: Bool, includeUsage: Bool, chat: ChatService,
                        speech: SpeechService) async throws -> Response {
    let events = ChatAudio.events(spec: spec, messages: messages, options: options, voice: p.voice, chat: chat, speech: speech)
    let audioID = ChatAudio.newID()
    let expires = Int(Date().timeIntervalSince1970) + 3600
    guard stream else {
        var transcript = "", samples: [Float] = [], finish = "stop", usage = ChatUsage(promptTokens: 0, completionTokens: 0)
        var calls: [ToolCallWire] = []
        for try await e in events {
            switch e {
            case .transcript(let t): transcript += t
            case .audio(let a): samples += a
            case .toolCall(let name, let arguments): calls.append(ToolCallWire(name: name, arguments: arguments))
            case .done(let f, let u): finish = f; usage = u
            }
        }
        // A tool call instead of an answer has nothing to say yet (as OpenAI: audio is null, tool_calls is set).
        var audio: ChatAudioWire?
        if !samples.isEmpty || calls.isEmpty {
            let data = try await ChatAudio.encode(samples, as: p.format, encoder: speech.encoder)
            audio = .init(id: audioID, data: data.base64EncodedString(), expires_at: expires,
                          transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return json(ChatCompletionWire(id: id, created: created, model: spec.id, choices: [
            .init(message: .init(content: nil, audio: audio, tool_calls: calls.isEmpty ? nil : calls),
                  finish_reason: calls.isEmpty ? finish : "tool_calls"),
        ], usage: ChatUsageWire(usage)))
    }
    return sse { write in
        func chunk(_ delta: ChatChunkWire.Choice.Delta, finish: String? = nil) -> ChatChunkWire {
            ChatChunkWire(id: id, created: created, model: spec.id, choices: [.init(delta: delta, finish_reason: finish)])
        }
        try await write(nil, chunk(.init(role: "assistant")))
        var calls = 0
        for try await e in events {
            switch e {
            case .toolCall(let name, let arguments):
                try await write(nil, chunk(.init(tool_calls: [ToolCallWire(index: calls, name: name, arguments: arguments)])))
                calls += 1
            case .transcript(let t):
                try await write(nil, chunk(.init(audio: .init(id: audioID, transcript: t))))
            case .audio(let a):
                try await write(nil, chunk(.init(audio: .init(id: audioID, data: PCM.pcm16LE(from: a).base64EncodedString()))))
            case .done(let finish, let usage):
                try await write(nil, chunk(.init(audio: .init(id: audioID, expires_at: expires))))
                try await write(nil, chunk(.init(), finish: calls > 0 ? "tool_calls" : finish))
                if includeUsage {
                    try await write(nil, ChatChunkWire(id: id, created: created, model: spec.id, choices: [], usage: ChatUsageWire(usage)))
                }
            }
        }
        try await writeRaw(write, "[DONE]")
    }
}

/// A model without a video processor would silently drop the frames, so refuse instead.
func requireMediaSupport(_ chat: ChatService, _ spec: ModelSpec, _ messages: [ChatMessage]) async throws {
    if messages.contains(where: { !$0.videos.isEmpty }), await !chat.supportsVideo(spec) {
        throw HTTPError(.badRequest, message: "Model '\(spec.id)' does not accept video.")
    }
    if messages.contains(where: { !$0.audios.isEmpty }), await !chat.supportsAudio(spec) {
        throw HTTPError(.badRequest, message: "Model '\(spec.id)' does not accept audio.")
    }
}

func addChatRoutes(to g: RouterGroup<SynapseContext>, chat: ChatService, images: ImageService, speech: SpeechService,
                   tools backends: ToolBackends, settings: SettingsBox) {
    g.post("chat/completions") { req, ctx in
        let raw = try await rawBody(req, ctx)
        if let proxied = try await proxyToVOOM(raw, path: "v1/chat/completions", chat: chat, settings: settings) { return proxied }
        let body = try decodeJSON(ChatCompletionRequest.self, raw)
        let sampling = try SamplingFields.read(raw)
        let spec = try await resolveChat(chat, body.model)
        let messages = try await ImageFetcher.messages(try ChatParse.chatMessages(body.messages))
        try await requireMediaSupport(chat, spec, messages)
        let effort = reasoning(body.reasoning_effort)
        var options = ChatOptions(maxTokens: body.max_completion_tokens ?? body.max_tokens, temperature: body.temperature,
                                  topP: body.top_p, enableThinking: effort.enabled)
        options.thinkingBudget = effort.budget
        sampling.apply(to: &options)
        var (server, clientTools) = try ServerTools.split(body.tools, settings: settings.current.tools)
        if body.web_search_options != nil {
            guard server.settings.searchProvider != .off else { throw ChatParse.bad("Web search is turned off in Synapse's settings (Server → Built-in tools).") }
            server.webSearch = true
        }
        if body.tool_choice?.string == "none" { server = ServerTools() }
        options.tools = try ChatParse.functionTools(clientTools, choice: body.tool_choice)
        let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let created = Int(Date().timeIntervalSince1970)

        if let audio = try ChatAudio.params(modalities: body.modalities, audio: body.audio, stream: body.stream == true) {
            return try await audioReply(audio, id: id, created: created, spec: spec, messages: messages, options: options,
                                        stream: body.stream == true, includeUsage: body.stream_options?["include_usage"]?.bool == true,
                                        chat: chat, speech: speech)
        }

        let stops = stopSequences(body.stop)
        let services = backends.services(req, ctx, server)
        let events = try await chatWithServerTools(server, services: services, spec: spec, messages: messages, options: options,
                                                   wrap: { applyStops($0, stops) })
        guard body.stream == true else {
            var text = "", thinking = "", finish = "stop", calls: [ToolCallWire] = [], used: [SynapseToolWire] = []
            var usage = ChatUsage(promptTokens: 0, completionTokens: 0)
            for try await e in events {
                switch e {
                case .chat(.delta(let s)): text += s
                case .chat(.reasoning(let s)): thinking += s
                case .chat(.done(let f, let u)): finish = f; usage = u
                case .chat(.toolCall(let name, let arguments)): calls.append(ToolCallWire(name: name, arguments: arguments))
                case .chat(.progress), .toolStarted: break
                case .toolFinished(let call):
                    used.append(SynapseToolWire(call, running: false))
                    text += call.markdown
                }
            }
            return json(ChatCompletionWire(id: id, created: created, model: spec.id, choices: [
                .init(message: .init(content: text.isEmpty && !calls.isEmpty ? nil : text, tool_calls: calls.isEmpty ? nil : calls,
                                     reasoning_content: thinking.isEmpty ? nil : thinking, synapse_tool_calls: used.isEmpty ? nil : used),
                      finish_reason: calls.isEmpty ? finish : "tool_calls"),
            ], usage: ChatUsageWire(usage)))
        }

        let includeUsage = body.stream_options?["include_usage"]?.bool == true
        return sse { write in
            func chunk(_ delta: ChatChunkWire.Choice.Delta, finish: String? = nil) -> ChatChunkWire {
                ChatChunkWire(id: id, created: created, model: spec.id, choices: [.init(delta: delta, finish_reason: finish)])
            }
            try await write(nil, chunk(.init(role: "assistant", content: "")))
            var calls = 0
            for try await event in events {
                switch event {
                case .chat(.delta(let s)):
                    try await write(nil, chunk(.init(content: s)))
                case .chat(.reasoning(let s)):
                    try await write(nil, chunk(.init(reasoning_content: s)))
                case .chat(.toolCall(let name, let arguments)):
                    try await write(nil, chunk(.init(tool_calls: [ToolCallWire(index: calls, name: name, arguments: arguments)])))
                    calls += 1
                case .chat(.progress(let p)):
                    var c = chunk(.init())
                    c.synapse_progress = p.wire()
                    try await write(nil, c)
                case .toolStarted(let call):
                    var c = chunk(.init())
                    c.synapse_tool_call = SynapseToolWire(call, running: true)
                    try await write(nil, c)
                case .toolFinished(let call):
                    var c = chunk(.init(content: call.markdown.isEmpty ? nil : call.markdown))
                    c.synapse_tool_call = SynapseToolWire(call, running: false)
                    try await write(nil, c)
                case .chat(.done(let finish, let usage)):
                    try await write(nil, chunk(.init(), finish: calls > 0 ? "tool_calls" : finish))
                    if includeUsage {
                        try await write(nil, ChatChunkWire(id: id, created: created, model: spec.id, choices: [], usage: ChatUsageWire(usage)))
                    }
                }
            }
            try await writeRaw(write, "[DONE]")
        }
    }

    g.post("responses") { req, ctx in
        let raw = try await rawBody(req, ctx)
        if let proxied = try await proxyToVOOM(raw, path: "v1/responses", chat: chat, settings: settings) { return proxied }
        let body = try decodeJSON(ResponsesRequest.self, raw)
        let sampling = try SamplingFields.read(raw)
        var (server, clientTools) = try ServerTools.split(body.tools, settings: settings.current.tools)
        // A request for image_generation alone keeps its own path: partial images, a forced prompt writer, and image-only
        // setups. Tools the settings add to every chat don't count; they'd need a chat model this path may not have.
        if let image = server.image, body.tools?.count == 1, body.tools?.first?["type"]?.string == "image_generation" {
            return try await respondWithImageTool(body, tools: body.tools ?? [], config: image, chat: chat, images: images)
        }
        if body.tool_choice?.string == "none" { server = ServerTools() }
        let spec = try await resolveChat(chat, body.model)
        let messages = try await ImageFetcher.messages(try ChatParse.responseMessages(body.input, instructions: body.instructions))
        try await requireMediaSupport(chat, spec, messages)
        let effort = reasoning(body.reasoning?["effort"]?.string)
        var options = ChatOptions(maxTokens: body.max_output_tokens, temperature: body.temperature,
                                  topP: body.top_p, enableThinking: effort.enabled)
        options.thinkingBudget = effort.budget
        sampling.apply(to: &options)
        options.tools = try ChatParse.functionTools(clientTools, choice: body.tool_choice)
        let hasTools = !options.tools.isEmpty || !server.isEmpty
        let respID = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let created = Int(Date().timeIntervalSince1970)
        let services = backends.services(req, ctx, server)
        let events = try await chatWithServerTools(server, services: services, spec: spec, messages: messages, options: options)

        @Sendable func response(status: String, output: [ResponseOutputItemWire] = [], text: String = "", usage: ChatUsage? = nil,
                                finish: String? = nil) -> ResponseWire {
            let incomplete = finish == "length"
            return ResponseWire(
                id: respID, created_at: created, status: status == "completed" && incomplete ? "incomplete" : status, model: spec.id,
                output: output, output_text: text, usage: usage.map(ResponseWire.Usage.init),
                incomplete_details: incomplete ? .init(reason: "max_output_tokens") : nil,
                instructions: body.instructions, max_output_tokens: body.max_output_tokens,
                temperature: body.temperature, top_p: body.top_p,
                tool_choice: body.tool_choice ?? .string(hasTools ? "auto" : "none"), tools: body.tools ?? [])
        }

        /// Consumes the generation, reporting each stream event to `emit`, and returns the finished response.
        @Sendable func run(streaming: Bool, _ emit: (ResponsesAssembler.Event) async throws -> Void) async throws -> ResponseWire {
            var asm = ResponsesAssembler()
            var usage: ChatUsage?, finish = "stop"
            for try await e in events {
                switch e {
                case .chat(.reasoning(let s)): asm.reasoning(s)
                case .chat(.delta(let s)): asm.text(s)
                case .chat(.toolCall(let name, let arguments)): asm.functionCall(name: name, arguments: arguments)
                // Not an OpenAI event; SDKs pass unknown event types through, and this shows load and prompt reading.
                case .chat(.progress(let p)): try await emit(("response.synapse_progress", p.wire().values))
                case .chat(.done(let f, let u)): finish = f; usage = u
                case .toolStarted(let call): asm.toolStarted(call)
                case .toolFinished(let call): asm.toolFinished(call)
                }
                for event in asm.drain() { try await emit(event) }
            }
            asm.finish(messageStatus: finish == "length" ? "incomplete" : "completed", alwaysMessage: streaming)
            for event in asm.drain() { try await emit(event) }
            return response(status: "completed", output: asm.items, text: asm.text, usage: usage, finish: finish)
        }

        guard body.stream == true else { return json(try await run(streaming: false) { _ in }) }
        return sse { write in
            var seq = 0
            func event(_ type: String, _ fields: [String: any Encodable & Sendable]) async throws {
                var payload = fields
                payload["type"] = type
                payload["sequence_number"] = seq
                seq += 1
                try await write(type, AnyEncodableDict(payload))
            }
            try await event("response.created", ["response": response(status: "in_progress")])
            try await event("response.in_progress", ["response": response(status: "in_progress")])
            let final = try await run(streaming: true) { try await event($0.type, $0.fields) }
            try await event(final.status == "completed" ? "response.completed" : "response.incomplete", ["response": final])
        }
    }
}

/// Where /v1/images/files serves images for this request's client: its Host, and the key path when the key came that way.
func imageFileBase(_ req: Request, _ ctx: SynapseContext) -> String {
    let host = req.headers[HTTPField.Name("Host")!] ?? req.head.authority ?? "localhost"
    let keyPrefix = ctx.parameters.get("key").map { "k/\($0)/" } ?? ""
    return "http://\(host)/\(keyPrefix)v1/images/files/"
}

struct ReasoningTextPart: Encodable, Sendable { var type = "reasoning_text"; var text: String }

/// A Responses reasoning output item: the model's thinking as reasoning_text content (no summary is generated).
struct ReasoningItemWire: Encodable, Sendable {
    var type = "reasoning"
    var id: String
    var status = "completed"
    var summary: [String] = []
    var content: [ReasoningTextPart]
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

extension ChatProgress {
    /// The phase as Synapse reports it on APIs that have no event for it: phase is load_start, load_end (seconds),
    /// prompt_start, prompt (fraction of the prompt read, from engines that count it) or prompt_end.
    func wire(type: String? = nil) -> AnyEncodableDict {
        var o: [String: any Encodable & Sendable] = [:]
        switch self {
        case .loadStarted: o["phase"] = "load_start"
        case .loaded(let s): o["phase"] = "load_end"; o["seconds"] = s
        case .promptStarted: o["phase"] = "prompt_start"
        case .prompt(let f): o["phase"] = "prompt"; o["fraction"] = min(max(f, 0), 1)
        case .promptDone: o["phase"] = "prompt_end"
        }
        if let type { o["type"] = type }
        return AnyEncodableDict(o)
    }
}

/// OpenAI reasoning effort as thinking on/off plus a token budget: none/minimal off, low 1024, medium 4096,
/// high (and anything else) unlimited. Absent means off, as on Synapse's other routes.
func reasoning(_ effort: String?) -> (enabled: Bool, budget: Int?) {
    switch effort {
    case nil, "none", "minimal": (false, nil)
    case "low": (true, 1024)
    case "medium": (true, 4096)
    default: (true, nil)
    }
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
    let runtime = VOOMRuntime.shared(checkout: checkout, modelsRoot: chat.modelsRoot, models: chat.models)
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

func writeRaw(_ write: SSEWrite, _ raw: String) async throws {
    try await write("__raw__", raw)
}

private func sseFrame(_ event: String?, _ payload: any Encodable & Sendable) throws -> String {
    if event == "__raw__", let s = payload as? String { return "data: \(s)\n\n" }
    let data = try JSONEncoder().encode(payload)
    return (event.map { "event: \($0)\n" } ?? "") + "data: \(String(decoding: data, as: UTF8.self))\n\n"
}
