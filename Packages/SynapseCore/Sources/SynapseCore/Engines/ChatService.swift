import CoreImage
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXLMCommon
@preconcurrency import MLXVLM
@preconcurrency import Tokenizers

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var text: String
    /// Encoded image bytes (PNG, JPEG, HEIC...). Remote URLs are fetched at the API boundary.
    public var images: [Data]
    /// Local video files (MP4/MOV), already validated; frames are sampled by the model's processor.
    public var videos: [URL]
    /// Local 16 kHz WAV files for models that take audio input.
    public var audios: [URL]

    public init(role: Role, text: String, images: [Data] = [], videos: [URL] = [], audios: [URL] = []) {
        self.role = role; self.text = text; self.images = images; self.videos = videos; self.audios = audios
    }
}

public struct ChatOptions: Sendable, Equatable {
    public var maxTokens: Int?
    public var temperature: Float?
    public var topP: Float?
    /// Qwen3.5 thinking mode. Off by default so answers come back directly.
    public var enableThinking: Bool
    /// Function tools in OpenAI/HF chat-template form: {"type":"function","function":{name,description,parameters}}.
    public var tools: [ChatTool]
    /// Frames sampled evenly across each video (nil = 8).
    public var videoFrames: Int?

    public init(maxTokens: Int? = nil, temperature: Float? = nil, topP: Float? = nil, enableThinking: Bool = false,
                tools: [ChatTool] = [], videoFrames: Int? = nil) {
        self.maxTokens = maxTokens; self.temperature = temperature; self.topP = topP; self.enableThinking = enableThinking
        self.tools = tools; self.videoFrames = videoFrames
    }
}

/// A function tool offered to the chat model.
public struct ChatTool: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema object for the arguments, as JSON text.
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON
    }

    var spec: [String: any Sendable] {
        let params = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) as? [String: any Sendable] ?? [:]
        return ["type": "function", "function": ["name": name, "description": description, "parameters": params] as [String: any Sendable]]
    }
}

public struct ChatUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }
}

public enum ChatEvent: Sendable, Equatable {
    case delta(String)
    /// The model called a tool; `arguments` is a JSON object string.
    case toolCall(name: String, arguments: String)
    /// finishReason is OpenAI's: "stop" or "length".
    case done(finishReason: String, usage: ChatUsage)
}

public struct ChatToolCall: Sendable, Equatable {
    public var name: String
    public var arguments: String
}

public struct ChatResult: Sendable, Equatable {
    public var modelID: String
    public var text: String
    public var toolCalls: [ChatToolCall] = []
    public var finishReason: String
    public var usage: ChatUsage
}

public enum ChatError: Error, LocalizedError {
    case badImage, emptyConversation
    public var errorDescription: String? {
        switch self {
        case .badImage: return "An image could not be decoded."
        case .emptyConversation: return "The conversation has no messages."
        }
    }
}

/// Runs MLX chat/vision models. Loading and eviction go through the shared ModelManager; a lease is
/// held for the whole generation so a model is never unloaded mid-reply.
public actor ChatService {
    private let store: ModelStore
    let models: ModelManager
    nonisolated var modelsRoot: URL { store.root }
    static let defaultMaxTokens = 4096

    public init(store: ModelStore, models: ModelManager = ModelManager()) {
        self.store = store; self.models = models
    }

    /// A model takes video when its snapshot ships a video preprocessor (Qwen3.5 does).
    public func supportsVideo(_ spec: ModelSpec) async -> Bool {
        guard let folder = await store.folder(for: spec.id) else { return false }
        return FileManager.default.fileExists(atPath: folder.appending(path: "video_preprocessor_config.json").path)
    }

    /// A model takes audio when its config declares an audio tower.
    public func supportsAudio(_ spec: ModelSpec) async -> Bool {
        guard let folder = await store.folder(for: spec.id),
              let data = try? Data(contentsOf: folder.appending(path: "config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return config["audio_config"] != nil
    }

    public func resolve(_ requested: String?) async throws -> ModelSpec {
        try ModelResolver.resolveChat(requested: requested, downloaded: await store.downloaded)
    }

    /// Streams deltas then a final `.done`. Cancelling the consuming task stops generation.
    public func stream(model spec: ModelSpec, messages: [ChatMessage], options: ChatOptions) async throws
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        guard !messages.isEmpty else { throw ChatError.emptyConversation }
        let lease = try await containerLease(for: spec)
        let container = lease.value
        let input = try Self.userInput(messages, options)
        let toolSpecs = input.tools
        let maxTokens = options.maxTokens ?? Self.defaultMaxTokens
        let params = GenerateParameters(maxTokens: maxTokens, temperature: options.temperature ?? 0.7,
                                        topP: options.topP ?? 0.8)
        return try await run(container: container, lease: lease, params: params, tools: toolSpecs,
                             stripThinking: !options.enableThinking) { try await container.prepare(input: input) }
    }

    /// Raw text continuation (legacy OpenAI Completions): the prompt is tokenized as-is, with no chat template.
    public func streamText(model spec: ModelSpec, prompt: String, options: ChatOptions) async throws
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        guard !prompt.isEmpty else { throw ChatError.emptyConversation }
        let lease = try await containerLease(for: spec)
        let container = lease.value
        let params = GenerateParameters(maxTokens: options.maxTokens ?? Self.defaultMaxTokens,
                                        temperature: options.temperature ?? 0.7, topP: options.topP ?? 0.8)
        return try await run(container: container, lease: lease, params: params, tools: nil, stripThinking: false) {
            let tokens = await container.perform { ctx in ctx.tokenizer.encode(text: prompt) }
            return LMInput(tokens: MLXArray(tokens.map(Int32.init)))
        }
    }

    /// Holds the GPU gate from prefill to the end of generation and turns MLX events into `ChatEvent`s.
    private func run(container: ModelContainer, lease: ModelLease<ModelContainer>, params: GenerateParameters,
                     tools: [[String: any Sendable]]?, stripThinking: Bool,
                     input makeInput: () async throws -> sending LMInput) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        await GPUGate.shared.acquire()
        let releaseGate = GateRelease()
        let generation: AsyncStream<Generation>
        do {
            let lmInput = try await makeInput()
            generation = try await container.generate(input: lmInput, parameters: params, tools: tools)
        } catch {
            releaseGate()
            lease.release()
            throw error
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var filter = ThinkFilter(enabled: stripThinking)
                for await event in generation {
                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let s):
                        let out = filter.feed(s)
                        if !out.isEmpty { continuation.yield(.delta(out)) }
                    case .info(let info):
                        let tail = filter.finish()
                        if !tail.isEmpty { continuation.yield(.delta(tail)) }
                        let reason = info.stopReason == .length ? "length" : "stop"
                        continuation.yield(.done(finishReason: reason, usage: ChatUsage(
                            promptTokens: info.promptTokenCount, completionTokens: info.generationTokenCount)))
                    case .toolCall(let call):
                        let args = (try? JSONEncoder().encode(call.function.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        continuation.yield(.toolCall(name: call.function.name, arguments: args))
                    default:
                        break
                    }
                }
                releaseGate()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                releaseGate()
                lease.release()
            }
        }
    }

    public func complete(model spec: ModelSpec, messages: [ChatMessage], options: ChatOptions) async throws -> ChatResult {
        var text = ""
        var finish = "stop"
        var usage = ChatUsage(promptTokens: 0, completionTokens: 0)
        var calls: [ChatToolCall] = []
        for try await event in try await stream(model: spec, messages: messages, options: options) {
            switch event {
            case .delta(let s): text += s
            case .done(let f, let u): finish = f; usage = u
            case .toolCall(let name, let arguments): calls.append(ChatToolCall(name: name, arguments: arguments))
            }
        }
        return ChatResult(modelID: spec.id, text: text, toolCalls: calls, finishReason: finish, usage: usage)
    }

    /// Prompt tokens for `messages` after the chat template (and image tokens), without generating.
    public func countTokens(model spec: ModelSpec, messages: [ChatMessage], options: ChatOptions) async throws -> Int {
        guard !messages.isEmpty else { throw ChatError.emptyConversation }
        let lease = try await containerLease(for: spec)
        defer { lease.release() }
        let container = lease.value
        return try await GPUGate.shared.run {
            try await container.prepare(input: try Self.userInput(messages, options)).text.tokens.size
        }
    }

    private static func userInput(_ messages: [ChatMessage], _ options: ChatOptions) throws -> UserInput {
        let chat: [Chat.Message] = try messages.map { m in
            let images = try m.images.map { data -> UserInput.Image in
                guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ChatError.badImage }
                return .ciImage(ci)
            }
            let videos = m.videos.map { UserInput.Video.url($0) }
            switch m.role {
            case .system: return .system(m.text, images: images, videos: videos)
            case .user: return .user(m.text, images: images, videos: videos, audios: m.audios.map { UserInput.Audio.url($0) })
            case .assistant: return .assistant(m.text, images: images, videos: videos)
            }
        }
        var processing = UserInput.Processing()
        processing.video = .init(targetFrames: options.videoFrames ?? 8)
        // Cap image tokens: phone photos otherwise become thousands of tokens on small models.
        processing.maxPixels = 1024 * 1024
        return UserInput(chat: chat, processing: processing, tools: options.tools.isEmpty ? nil : options.tools.map(\.spec),
                              additionalContext: ["enable_thinking": options.enableThinking])
    }

    private func containerLease(for spec: ModelSpec) async throws -> ModelLease<ModelContainer> {
        guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        return try await models.lease(spec.id, as: ModelContainer.self, estimatedBytes: spec.estimatedBytes) {
            let container = try await VLMModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader())
            return (container, unload: {})
        }
    }
}

/// Drops a leading `<think>...</think>` block from streamed text.
struct ThinkFilter {
    private var enabled: Bool
    private var buffer = ""
    private var decided = false
    private var inThink = false

    init(enabled: Bool) { self.enabled = enabled; decided = !enabled }

    mutating func feed(_ s: String) -> String {
        guard enabled else { return s }
        buffer += s
        if !decided {
            let trimmed = buffer.drop { $0.isWhitespace }
            if trimmed.isEmpty || "<think>".hasPrefix(trimmed) { return "" }
            decided = true
            inThink = trimmed.hasPrefix("<think>")
            if !inThink { defer { buffer = "" }; return String(trimmed) }
        }
        if inThink {
            guard let end = buffer.range(of: "</think>") else { return "" }
            inThink = false
            let rest = String(buffer[end.upperBound...].drop { $0.isWhitespace })
            buffer = ""
            return rest
        }
        defer { buffer = "" }
        return buffer
    }

    mutating func finish() -> String {
        defer { buffer = "" }
        return (enabled && (inThink || !decided)) ? "" : buffer
    }
}

/// Bridges swift-transformers tokenizers into mlx-swift-lm (what the MLXHuggingFace macro generates).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
