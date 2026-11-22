import Foundation
import Hummingbird

// Responses API `image_generation` tool. Qwen3.5 writes the image prompt (OpenAI's `revised_prompt`): when the
// tool is forced it rewrites the request directly, otherwise it decides through a `generate_image` function call.

struct ImageToolConfig {
    var model: String?
    var size: String?
    var quality: String
    var outputFormat: String
    var outputCompression: Int?
    var partialImages: Int
    var action: String   // generate | edit | auto

    init(_ tool: JSONValue) throws {
        model = tool["model"]?.string
        size = tool["size"]?.string
        let q = tool["quality"]?.string ?? "auto"
        guard ["low", "medium", "high", "auto"].contains(q) else { throw ChatParse.bad("Unsupported quality '\(q)'.") }
        quality = q
        outputFormat = tool["output_format"]?.string ?? "png"
        guard ["png", "jpeg", "webp"].contains(outputFormat) else { throw ChatParse.bad("Unsupported output_format '\(outputFormat)'.") }
        if outputFormat == "webp", !ImageEncoding.supportsWebP() { throw ChatParse.bad("webp output is not supported on this system") }
        outputCompression = tool["output_compression"]?.number.map(Int.init)
        partialImages = tool["partial_images"]?.number.map(Int.init) ?? 0
        guard (0...3).contains(partialImages) else { throw ChatParse.bad("partial_images must be between 0 and 3.") }
        action = tool["action"]?.string ?? "auto"
        guard ["generate", "edit", "auto"].contains(action) else { throw ChatParse.bad("Unsupported action '\(action)'.") }
    }
}

struct ImageGenerationCallWire: Encodable, Sendable {
    var type = "image_generation_call"
    var id: String
    var status: String
    var result: String?
    var revised_prompt: String?
    var action: String?
    var output_format: String
    var size: String
    var quality: String
    var background = "opaque"
}

enum ResponseOutputItemWire: Encodable, Sendable {
    case message(ResponseWire.Message)
    case image(ImageGenerationCallWire)
    case functionCall(FunctionCallWire)
    case reasoning(ReasoningItemWire)
    case webSearch(WebSearchCallWire)
    case synapseTool(SynapseToolCallWire)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let m): try m.encode(to: encoder)
        case .image(let i): try i.encode(to: encoder)
        case .functionCall(let f): try f.encode(to: encoder)
        case .reasoning(let r): try r.encode(to: encoder)
        case .webSearch(let w): try w.encode(to: encoder)
        case .synapseTool(let t): try t.encode(to: encoder)
        }
    }
}

/// A Responses function call output item; the client answers with a function_call_output input item.
struct FunctionCallWire: Encodable, Sendable {
    var type = "function_call"
    var id = "fc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
    var call_id = ToolCallWire.newID()
    var name: String
    var arguments: String
    var status = "completed"

    func with(status: String, arguments: String? = nil) -> FunctionCallWire {
        var f = self
        f.status = status
        if let arguments { f.arguments = arguments }
        return f
    }
}

struct ImageToolResponseWire: Encodable, Sendable {
    var id: String
    var object = "response"
    var created_at: Int
    var status: String
    var model: String
    var output: [ResponseOutputItemWire]
    var output_text: String
    var usage: ResponseWire.Usage?
    var error: String? = nil
    var incomplete_details: String? = nil
    var instructions: String?
    var max_output_tokens: Int?
    var temperature: Float?
    var top_p: Float?
    var parallel_tool_calls = false
    var tool_choice: JSONValue
    var tools: [JSONValue]
    var text = ["format": ["type": "text"]]
}

private let promptWriterInstruction = """
    You write prompts for an image generator. Read the conversation and reply with one detailed prompt (subject, \
    setting, style, lighting) that fulfils the user's latest request. Reply with the prompt only.
    """

private let generateImageTool = ChatTool(
    name: "generate_image",
    description: "Create or edit an image. Call this whenever the user asks for a picture, drawing, photo or image edit.",
    parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed description of the image to create"}},"required":["prompt"]}"#)

private func newID(_ prefix: String) -> String {
    prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

/// `config`: the request's image_generation tool with the app's defaults filled in (ServerTools.split).
func respondWithImageTool(_ body: ResponsesRequest, tools: [JSONValue], config: ImageToolConfig, chat: ChatService, images: ImageService) async throws -> Response {
    let choice = body.tool_choice ?? .string("auto")
    let forced = choice.string == "required" || choice["type"]?.string == "image_generation"
    if choice.string == "none" { throw ChatParse.bad("tool_choice 'none' with an image_generation tool is not supported; omit tools instead.") }

    let parsed = try ChatParse.responseMessages(body.input, instructions: body.instructions)
    let messages = try await ImageFetcher.messages(parsed)
    let sourceImages = messages.last(where: { $0.role == .user })?.images ?? []
    let wantsEdit = config.action == "edit" || (config.action == "auto" && !sourceImages.isEmpty)
    if config.action == "edit" && sourceImages.isEmpty { throw ChatParse.bad("action 'edit' needs an input image.") }

    let imageSpec: ModelSpec
    do { imageSpec = try await images.resolve(config.model, edit: wantsEdit) } catch { throw mapResolve(error) }
    // Without a chat model the user's own words become the prompt, so image tools work on image-only setups.
    let chatSpec: ModelSpec?
    do { chatSpec = try await chat.resolve(body.model) } catch ResolveError.noChatModel where body.model == nil {
        chatSpec = nil
    } catch { throw mapResolve(error) }
    let (width, height) = try ImageService.parseSize(config.size)
    let size = "\(width)x\(height)"
    let quality = config.quality == "auto" ? "medium" : config.quality
    let respID = newID("resp_"), callID = newID("ig_"), msgID = newID("msg_")
    let created = Int(Date().timeIntervalSince1970)
    let options = ChatOptions(maxTokens: body.max_output_tokens ?? 512, temperature: body.temperature, topP: body.top_p)

    @Sendable func wire(_ status: String, _ output: [ResponseOutputItemWire], usage: ChatUsage?, text: String = "") -> ImageToolResponseWire {
        ImageToolResponseWire(id: respID, created_at: created, status: status, model: chatSpec?.id ?? imageSpec.id, output: output,
                              output_text: text, usage: usage.map(ResponseWire.Usage.init), instructions: body.instructions,
                              max_output_tokens: body.max_output_tokens, temperature: body.temperature, top_p: body.top_p,
                              tool_choice: choice, tools: tools)
    }

    /// Decides whether to draw and with which prompt. nil prompt = plain text reply in `text`.
    @Sendable func plan() async throws -> (prompt: String?, text: String, usage: ChatUsage) {
        guard let chatSpec else {
            let text = messages.last(where: { $0.role == .user })?.text ?? ""
            return (text, "", ChatUsage(promptTokens: 0, completionTokens: 0))
        }
        if forced {
            let r = try await chat.complete(model: chatSpec, messages: [ChatMessage(role: .system, text: promptWriterInstruction)] + messages,
                                            options: options)
            let prompt = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (prompt.isEmpty ? messages.last?.text ?? "" : prompt, "", r.usage)
        }
        var opts = options
        opts.tools = [generateImageTool]
        let r = try await chat.complete(model: chatSpec, messages: messages, options: opts)
        if let call = r.toolCalls.first(where: { $0.name == generateImageTool.name }),
           let args = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any],
           let prompt = args["prompt"] as? String, !prompt.isEmpty {
            return (prompt, "", r.usage)
        }
        return (nil, r.text, r.usage)
    }

    @Sendable func call(_ status: String, prompt: String?, result: String? = nil) -> ImageGenerationCallWire {
        ImageGenerationCallWire(id: callID, status: status, result: result, revised_prompt: prompt,
                                action: wantsEdit ? "edit" : "generate", output_format: config.outputFormat, size: size, quality: quality)
    }

    @Sendable func draw(_ prompt: String, progress: @escaping @Sendable (Int, ImageProgress) -> Void) async throws -> String {
        let request = ImageRequest(prompt: prompt, width: width, height: height, inputImages: wantsEdit ? sourceImages : [])
        let pngs: [Data]
        do { pngs = try await images.generate(model: imageSpec, request: request, count: 1, progress: progress) }
        catch { throw mapImageError(error) }
        return try ImageEncoding.encode(pngs[0], format: config.outputFormat, compression: config.outputCompression).base64EncodedString()
    }

    guard body.stream == true else {
        let p = try await plan()
        guard let prompt = p.prompt else {
            let msg = ResponseWire.Message(id: msgID, status: "completed", content: [.init(text: p.text)])
            return json(wire("completed", [.message(msg)], usage: p.usage, text: p.text))
        }
        let b64 = try await draw(prompt) { _, _ in }
        return json(wire("completed", [.image(call("completed", prompt: prompt, result: b64))], usage: p.usage))
    }

    let partials = config.partialImages
    return sse { write in
        var seq = 0
        func event(_ type: String, _ fields: [String: any Encodable & Sendable]) async throws {
            var payload = fields
            payload["type"] = type
            payload["sequence_number"] = seq
            seq += 1
            try await write(type, AnyEncodableDict(payload))
        }
        try await event("response.created", ["response": wire("in_progress", [], usage: nil)])
        try await event("response.in_progress", ["response": wire("in_progress", [], usage: nil)])
        let p = try await plan()
        guard let prompt = p.prompt else {
            let done = ResponseWire.Message(id: msgID, status: "completed", content: [.init(text: p.text)])
            try await event("response.output_item.added", ["output_index": 0, "item": AnyEncodableDict(
                ["type": "message", "id": msgID, "status": "in_progress", "role": "assistant", "content": [String]()])])
            try await event("response.content_part.added", ["item_id": msgID, "output_index": 0, "content_index": 0, "part": OutputTextPart(text: "")])
            try await event("response.output_text.delta", ["item_id": msgID, "output_index": 0, "content_index": 0, "delta": p.text, "logprobs": [String]()])
            try await event("response.output_text.done", ["item_id": msgID, "output_index": 0, "content_index": 0, "text": p.text, "logprobs": [String]()])
            try await event("response.content_part.done", ["item_id": msgID, "output_index": 0, "content_index": 0, "part": OutputTextPart(text: p.text)])
            try await event("response.output_item.done", ["output_index": 0, "item": done])
            try await event("response.completed", ["response": wire("completed", [.message(done)], usage: p.usage, text: p.text)])
            return
        }
        try await event("response.output_item.added", ["output_index": 0, "item": call("in_progress", prompt: nil)])
        try await event("response.image_generation_call.in_progress", ["item_id": callID, "output_index": 0])
        try await event("response.image_generation_call.generating", ["item_id": callID, "output_index": 0])

        // Partial previews arrive on the engine's callback; forward them in order through a stream.
        let (previews, sink) = AsyncStream.makeStream(of: Data.self)
        let picker = PartialPicker(count: partials)
        let drawing = Task { () throws -> String in
            defer { sink.finish() }
            return try await draw(prompt) { _, p in if let d = picker.pick(p) { sink.yield(d) } }
        }
        var index = 0
        for await preview in previews {
            let encoded = (try? ImageEncoding.encode(preview, format: config.outputFormat, compression: config.outputCompression)) ?? preview
            try await event("response.image_generation_call.partial_image", [
                "item_id": callID, "output_index": 0, "partial_image_index": index, "partial_image_b64": encoded.base64EncodedString(),
                "output_format": config.outputFormat, "size": size, "quality": quality, "background": "opaque"])
            index += 1
        }
        let b64 = try await drawing.value
        let done = call("completed", prompt: prompt, result: b64)
        try await event("response.image_generation_call.completed", ["item_id": callID, "output_index": 0])
        try await event("response.output_item.done", ["output_index": 0, "item": done])
        try await event("response.completed", ["response": wire("completed", [.image(done)], usage: p.usage)])
    }
}

/// Emits at most `count` previews, spread across the steps.
private final class PartialPicker: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = 0
    private let count: Int
    init(count: Int) { self.count = count }
    func pick(_ p: ImageProgress) -> Data? {
        guard let preview = p.preview, p.step < p.totalSteps else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard emitted < count, p.step >= max(1, (emitted + 1) * p.totalSteps / (count + 1)) else { return nil }
        emitted += 1
        return preview
    }
}

private func mapResolve(_ error: Error) -> Error {
    if let e = error as? ResolveError {
        return HTTPError(e == .noChatModel ? .serviceUnavailable : .badRequest, message: e.localizedDescription)
    }
    return mapImageError(error)
}
