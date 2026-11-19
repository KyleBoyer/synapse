import CoreImage
import CryptoKit
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXLLM
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

/// How the KV cache stores attention keys and values. Lower precision fits longer contexts and more cached prompts
/// in memory, at a small quality cost. Only affine quantization is offered: it is the scheme whose caches can be
/// copied (mlx-swift-lm's TurboQuant cache has no `copy()`, which the prompt cache needs).
public enum KVPrecision: String, Codable, Sendable, CaseIterable {
    case full, int8, int4

    public var label: String {
        switch self { case .full: "Full"; case .int8: "8-bit"; case .int4: "4-bit" }
    }

    /// Recurrent layers (Qwen3.5's GatedDeltaNet) stay as they are; only attention layers compress.
    var configuration: KVCacheConfiguration? {
        let bits: Int
        switch self { case .full: return nil; case .int8: bits = 8; case .int4: bits = 4 }
        return (try? AffineKVCacheConfiguration(bits: bits)).map {
            KVCacheConfiguration(strategy: .affine($0), compatibility: .allowPartial)
        }
    }

    /// llama-server cache types (flash attention, on by default, handles quantized V).
    var llamaArgs: [String] {
        switch self {
        case .full: []
        case .int8: ["-ctk", "q8_0", "-ctv", "q8_0"]
        case .int4: ["-ctk", "q4_0", "-ctv", "q4_0"]
        }
    }

    /// mlx-vlm's KV_BITS environment value.
    var mlxVLMBits: String? {
        switch self { case .full: nil; case .int8: "8"; case .int4: "4" }
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
    /// Prompt tokens read from the prompt cache instead of being processed (part of `promptTokens`).
    public var cachedTokens: Int
    /// A draft model proposed tokens for this reply (speculative decoding ran). mlx-swift-lm reports no acceptance
    /// counts for draft-model speculation, only for MTP.
    public var drafted = false
    public var totalTokens: Int { promptTokens + completionTokens }

    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.cachedTokens = cachedTokens
    }
}

public enum ChatEvent: Sendable, Equatable {
    case delta(String)
    /// The model called a tool; `arguments` is a JSON object string.
    case toolCall(name: String, arguments: String)
    /// finishReason is OpenAI's: "stop" or "length".
    case done(finishReason: String, usage: ChatUsage)
    /// Load and prompt processing, before the first delta.
    case progress(ChatProgress)
}

/// What a chat request does before its first token (LM Studio's model_load and prompt_processing stream events).
/// Loading is reported only when the model was not resident. A prompt fraction comes only from engines that count
/// processed tokens (llama.cpp); in-process MLX and mlx-vlm report start and end.
public enum ChatProgress: Sendable, Equatable {
    case loadStarted
    case loaded(seconds: Double)
    case promptStarted
    case prompt(fraction: Double)
    case promptDone
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
    /// Memory each loaded model may spend on prompt-cache checkpoints.
    private var promptCacheBytes: Int
    /// Disk space for saved checkpoints, all models together (0 turns saving off).
    private var diskCacheBytes: Int
    private var promptCaches: [String: PromptCache] = [:]
    private var kvPrecision: KVPrecision = .full
    /// Main model id -> draft model id for speculative decoding.
    private var draftModels: [String: String] = [:]
    nonisolated var diskCacheRoot: URL { store.root.appending(path: "cache", directoryHint: .isDirectory) }

    public init(store: ModelStore, models: ModelManager = ModelManager(), promptCacheBytes: Int = ChatService.defaultPromptCacheBytes,
                diskCacheBytes: Int = 10 << 30) {
        self.store = store; self.models = models; self.promptCacheBytes = promptCacheBytes; self.diskCacheBytes = diskCacheBytes
    }

    /// Takes effect for models loaded from now on; caches of loaded models keep their current disk setting.
    public func setDiskCacheLimit(_ bytes: Int) { diskCacheBytes = bytes }

    /// Speculative decoding for `id`: a smaller model with the same tokenizer proposes tokens the main model checks
    /// in one pass. Output is unchanged; nil turns it off.
    public func setDraftModel(_ draft: String?, for id: String) { draftModels[id] = draft }

    /// Downloaded in-process chat models that can draft for `spec`: smaller, with an identical tokenizer, and both
    /// built only from full attention (see `rewindable`). Empty for Qwen3.5 and other hybrid models.
    public func draftCandidates(for spec: ModelSpec) async -> [ModelSpec] {
        guard spec.engine == .mlx, let folder = await store.folder(for: spec.id), Self.rewindable(folder),
              let mine = Self.tokenizerHash(folder) else { return [] }
        var out: [ModelSpec] = []
        for d in await store.downloaded.compactMap(Catalog.spec) where d.engine == .mlx && d.id != spec.id && d.approxMB < spec.approxMB {
            if let f = await store.folder(for: d.id), Self.rewindable(f), Self.tokenizerHash(f) == mine { out.append(d) }
        }
        return out.sorted { $0.approxMB < $1.approxMB }
    }

    /// Speculative decoding rewinds rejected draft tokens, which needs every cache layer to be trimmable: recurrent
    /// layers (Qwen3.5's linear attention, LFM's conv) never are, and sliding-window layers stop being once the window
    /// fills. So only models whose layers are all full attention qualify; configs without `layer_types` are.
    static func rewindable(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appending(path: "config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let text = config["text_config"] as? [String: Any] ?? [:]
        let types = (text["layer_types"] ?? config["layer_types"]) as? [String] ?? []
        return types.allSatisfy { $0 == "full_attention" }
    }

    private static func tokenizerHash(_ folder: URL) -> Data? {
        (try? Data(contentsOf: folder.appending(path: "tokenizer.json"))).map { Data(SHA256.hash(data: $0)) }
    }

    /// Cached prompts were built at the old precision, so they are dropped, and idle models unload so llama.cpp and
    /// mlx-vlm restart with the new cache type on next use.
    public func setKVPrecision(_ precision: KVPrecision) async {
        guard precision != kvPrecision else { return }
        kvPrecision = precision
        let ids = Array(promptCaches.keys)
        for c in promptCaches.values { await c.clear() }
        promptCaches = [:]
        for id in ids { _ = await models.unload(id) }
    }

    /// 1.5 GB on Macs with 16 GB or less, 4 GB above that.
    public static var defaultPromptCacheBytes: Int {
        ProcessInfo.processInfo.physicalMemory <= 16 << 30 ? 3 << 29 : 4 << 30
    }

    public func setPromptCacheLimit(_ bytes: Int) async {
        promptCacheBytes = bytes
        for c in promptCaches.values { await c.setLimit(bytes) }
    }

    /// Prompt-cache counters since launch for each model that has one (every request, the API included).
    public func cacheStats() async -> [String: PromptCacheStats] {
        var out: [String: PromptCacheStats] = [:]
        for (id, c) in promptCaches { out[id] = await c.stats }
        return out
    }

    /// Drops cached prompts for one model, or for all when `id` is nil; `disk` also deletes saved checkpoints.
    /// Counters are kept.
    public func clearCache(_ id: String? = nil, disk: Bool = false) async {
        for (key, c) in promptCaches where id == nil || key == id {
            await c.clear()
            if disk { await c.forgetDisk() }
        }
        // By path, so a model whose cache was not created this session is covered too.
        if disk { try? FileManager.default.removeItem(at: id.map(DiskPromptCache.folder(root: diskCacheRoot)) ?? diskCacheRoot) }
    }

    /// One cache per model id; it lives as long as the service, its entries are dropped when the model unloads.
    /// In-process MLX models pass their folder, which gives the cache a disk tier.
    private func promptCache(_ id: String, folder: URL? = nil) -> PromptCache {
        if let c = promptCaches[id] { return c }
        let disk = folder.flatMap { f in
            diskCacheBytes > 0 ? DiskPromptCache(root: diskCacheRoot, modelID: id, modelFolder: f, variant: kvPrecision.rawValue,
                                                 byteLimit: diskCacheBytes) : nil
        }
        let c = PromptCache(byteLimit: promptCacheBytes, disk: disk)
        promptCaches[id] = c
        return c
    }

    /// A model takes video when its snapshot ships a video preprocessor (Qwen3.5 does). mlx-vlm omni models take
    /// video, except Gemma 3n, which reads images and audio only.
    public func supportsVideo(_ spec: ModelSpec) async -> Bool {
        // Gemma 3n reads no video; Qwen3-Omni's video path in mlx-vlm 0.8.0 returns only control tokens.
        if spec.engine == .mlxvlm { return !["gemma-3n-e2b", "qwen3-omni-30b"].contains(spec.id) }
        guard let folder = await store.folder(for: spec.id) else { return false }
        return FileManager.default.fileExists(atPath: folder.appending(path: "video_preprocessor_config.json").path)
    }

    /// Audio input needs the mlx-vlm backend: in mlx-swift-lm no processor turns UserInput.audios into model
    /// input, and Gemma 4 (model_type gemma4) loads without its audio tower, even though its config lists one.
    public func supportsAudio(_ spec: ModelSpec) -> Bool { spec.engine == .mlxvlm }

    public func resolve(_ requested: String?) async throws -> ModelSpec {
        try ModelResolver.resolveChat(requested: requested, downloaded: await store.downloaded)
    }

    /// Streams progress (load, prompt), deltas, then a final `.done`. Cancelling the consuming task stops generation.
    /// Bad input and missing models throw here, before the stream; loading happens inside it, so its progress shows.
    public func stream(model spec: ModelSpec, messages: [ChatMessage], options: ChatOptions) async throws
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        guard !messages.isEmpty else { throw ChatError.emptyConversation }
        guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        if spec.engine == .mlxvlm { return Self.timeline { try await self.streamMLXVLM(spec, folder, messages, options, $0) } }
        if spec.engine == .gguf { return Self.timeline { try await self.streamLlama(spec, folder, messages, options, $0) } }
        _ = try Self.userInput(messages, options)
        // shortcut: requests with images, video or audio skip the prompt cache (prepared pixel tensors cannot be split
        // at a token boundary); use mlx's appendMediaSuffix path when chat-with-media reuse matters.
        let cacheable = messages.allSatisfy { $0.images.isEmpty && $0.videos.isEmpty && $0.audios.isEmpty }
        return Self.timeline { progress in
            let lease = try await self.containerLease(for: spec, progress: progress)
            let container = lease.value
            let cache = cacheable ? await self.promptCache(spec.id) : nil
            let params = Self.parameters(options, await self.kvPrecision)
            // shortcut: speculative decoding is text-only, like the prompt cache it builds on.
            let draftLease = cacheable ? try await self.draftLease(for: spec, progress: progress) : nil
            let draft: DraftModel? = if let draftLease { await DraftModel(draftLease.value) } else { nil }
            return try await self.run(lease: lease, draftLease: draftLease, stripThinking: !options.enableThinking, progress: progress) {
                try await container.perform { ctx in
                    let input = try Self.userInput(messages, options)
                    let tools = input.tools
                    let context = input.additionalContext
                    let lm = try await ctx.processor.prepare(input: input)
                    let tokens = lm.text.tokens.reshaped(-1).asArray(Int32.self).map(Int.init)
                    // The checkpoint goes where the history ends and the generation prompt begins: every follow-up
                    // request starts with exactly those tokens, however the reply is re-rendered.
                    let boundary = (ctx.tokenizer as? TokenizerBridge)?.generationPrompt(context: context)
                        .flatMap { gp in tokens.count > gp.count && Array(tokens.suffix(gp.count)) == gp ? tokens.count - gp.count : nil }
                    return try await Self.generate(ctx, lm, tokens: tokens, boundary: boundary, cache: cache, params: params, tools: tools,
                                                   draft: draft)
                }
            }
        }
    }

    typealias Progress = @Sendable (ChatProgress) -> Void

    /// Runs `open` inside the returned stream, so the consumer sees its load and prompt progress before any token.
    private static func timeline(_ open: @escaping @Sendable (@escaping Progress) async throws -> AsyncThrowingStream<ChatEvent, Error>)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    for try await e in try await open({ c.yield(.progress($0)) }) { c.yield(e) }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// Wraps a model load so it reports `.loadStarted` and `.loaded`; it runs only when the model is not resident.
    private static func timed<T: Sendable>(_ progress: @escaping Progress, _ load: () async throws -> T) async rethrows -> T {
        progress(.loadStarted)
        let start = ContinuousClock.now
        let value = try await load()
        let d = ContinuousClock.now - start
        progress(.loaded(seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18))
        return value
    }

    /// A model that answers in its own voice (`OmniVoices.canSpeak`); the lease lasts as long as the returned value.
    public func voice(_ spec: ModelSpec) async throws -> any RealtimeVoiceLLM {
        LeasedOmniVoice(try await OmniVoices.lease(spec, store: store, models: models))
    }

    /// Omni models run in their own mlx-vlm server; the lease keeps it alive and eviction stops it. Tool calls are not
    /// passed through: mlx-vlm parses them per model and only Qwen3.5's format is verified here.
    private func streamMLXVLM(_ spec: ModelSpec, _ folder: URL, _ messages: [ChatMessage], _ options: ChatOptions,
                              _ progress: @escaping Progress) async throws -> AsyncThrowingStream<ChatEvent, Error>
    {
        let cacheBytes = promptCacheBytes, diskBytes = diskCacheBytes, kv = kvPrecision
        let lease = try await models.lease(spec.id, as: MLXVLMServer.self, estimatedBytes: spec.estimatedResidentBytes,
                                           measure: { ProcessMemory.footprint(tree: $0.pid) }) {
            try await Self.timed(progress) {
                try await ModelPrep.prepareIfNeeded(spec, folder: folder)   // downloaded before prep existed
                let server = try await MLXVLMServer.launch(folder: folder, cacheBytes: cacheBytes, diskBytes: diskBytes, kv: kv)
                return (server, unload: { server.terminate() })
            }
        }
        let body: Data
        do { body = try MLXVLMChat.body(messages, options: options, model: lease.value.modelPath) } catch { lease.release(); throw error }
        await GPUGate.shared.acquire()
        let gate = GateRelease()
        return Self.recording(MLXVLMChat.stream(base: lease.value.base, body: body) { gate(); lease.release() }, into: promptCache(spec.id))
    }

    /// Server-backed models keep their own prefix cache; their usage reports feed the same counters as in-process ones.
    private static func recording(_ events: AsyncThrowingStream<ChatEvent, Error>, into cache: PromptCache)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    for try await e in events {
                        if case .done(_, let u) = e { await cache.record(prompt: u.promptTokens, cached: u.cachedTokens) }
                        c.yield(e)
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// GGUF models run in their own llama.cpp server (same OpenAI stream as mlx-vlm); eviction stops it.
    private func streamLlama(_ spec: ModelSpec, _ folder: URL, _ messages: [ChatMessage], _ options: ChatOptions,
                             _ progress: @escaping Progress) async throws -> AsyncThrowingStream<ChatEvent, Error>
    {
        let files = spec.files ?? [], cacheMiB = promptCacheBytes >> 20, kv = kvPrecision
        let lease = try await models.lease(spec.id, as: LlamaServer.self, estimatedBytes: spec.estimatedResidentBytes,
                                           measure: { ProcessMemory.footprint(tree: $0.pid) }) {
            try await Self.timed(progress) {
                let server = try await LlamaServer.launch(folder: folder, files: files, cacheMiB: cacheMiB, kv: kv)
                return (server, unload: { server.terminate() })
            }
        }
        let body: Data
        do {
            body = try MLXVLMChat.body(messages, options: options, model: lease.value.modelPath, promptProgress: true)
        } catch { lease.release(); throw error }
        await GPUGate.shared.acquire()
        let gate = GateRelease()
        return Self.recording(MLXVLMChat.stream(base: lease.value.base, body: body) { gate(); lease.release() }, into: promptCache(spec.id))
    }

    /// Raw text continuation (legacy OpenAI Completions): the prompt is tokenized as-is, with no chat template.
    public func streamText(model spec: ModelSpec, prompt: String, options: ChatOptions) async throws
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        guard !prompt.isEmpty else { throw ChatError.emptyConversation }
        guard spec.engine != .mlxvlm, spec.engine != .gguf else {
            throw EngineError.unsupported("Raw completions are not available for mlx-vlm or GGUF models; use chat.")
        }
        guard await store.folder(for: spec.id) != nil else { throw ResolveError.notDownloaded(spec.id) }
        return Self.timeline { progress in
            let lease = try await self.containerLease(for: spec, progress: progress)
            let container = lease.value
            let cache = await self.promptCache(spec.id)
            let params = Self.parameters(options, await self.kvPrecision)
            return try await self.run(lease: lease, draftLease: nil, stripThinking: false, progress: progress) {
                try await container.perform { ctx in
                    let tokens = ctx.tokenizer.encode(text: prompt)
                    // Raw text has no template, so a longer prompt extends this one directly.
                    return try await Self.generate(ctx, LMInput(tokens: MLXArray(tokens.map(Int32.init))), tokens: tokens,
                                                   boundary: tokens.count - 1, cache: cache, params: params, tools: nil)
                }
            }
        }
    }

    static func parameters(_ options: ChatOptions, _ precision: KVPrecision) -> GenerateParameters {
        var p = GenerateParameters(maxTokens: options.maxTokens ?? defaultMaxTokens,
                                   temperature: options.temperature ?? 0.7, topP: options.topP ?? 0.8)
        p.kvCache = precision.configuration
        return p
    }

    /// A started generation and how much of its prompt came from the cache.
    struct Started: Sendable {
        let generation: AsyncStream<Generation>
        let promptTokens: Int
        let cachedTokens: Int
        /// Runs after the last token, still under the GPU gate (saving a checkpoint to disk).
        var afterward: (@Sendable () async -> Void)? = nil
        var drafted = false
    }

    /// Prefills through the prompt cache and starts generating. Runs inside `perform`, where the model and the
    /// non-Sendable KV caches live. `boundary` is where to leave a checkpoint (nil: none).
    static func generate(_ ctx: ModelContext, _ lm: consuming sending LMInput, tokens: [Int], boundary: Int?,
                         cache: PromptCache?, params: GenerateParameters,
                         tools: [[String: any Sendable]]?, draft: DraftModel? = nil) async throws -> Started {
        guard let cache, tokens.count > 1 else {
            return Started(generation: try MLXLMCommon.generate(input: lm, parameters: params, context: ctx, tools: tools),
                           promptTokens: tokens.count, cachedTokens: 0)
        }
        let hit = await cache.lookup(tokens)
        var kv = try hit?.cache ?? makePromptCache(model: ctx.model, parameters: params)
        var state = hit?.state
        var fed = hit?.reused ?? 0
        if let boundary, boundary > fed, boundary < tokens.count {
            // TokenIterator's init prefills its whole input into `kv` (it also samples one token, which is dropped).
            let it = try TokenIterator(input: LMInput(tokens: MLXArray(tokens[fed..<boundary].map(Int32.init))),
                                       model: ctx.model, cache: kv, state: state, parameters: params)
            state = it.state
            fed = boundary
            // The iterator compressed its own copy of the array; `kv` still holds the full-precision layers with every
            // prefilled token, so compress them the same way before keeping and continuing from them.
            if let configuration = params.kvCache { _ = try applyKVCacheConfiguration(cache: &kv, configuration: configuration) }
            await cache.store(Array(tokens[0..<boundary]), .init(cache: kv.map { $0.copy() }, state: state, reused: boundary))
        }
        await cache.record(prompt: tokens.count, cached: hit?.reused ?? 0)
        let rest = LMInput(tokens: MLXArray(tokens[fed...].map(Int32.init)))
        let generation: AsyncStream<Generation>
        var drafted = false
        if let draft {
            // shortcut: the draft re-reads the cached prefix every request (it is small, so this is cheap); give it its
            // own prompt-cache entries if long prompts make that prefill show up in time to first token.
            let draftKV = try makePromptCache(model: draft.model, parameters: params)
            if fed > 0 {
                _ = try TokenIterator(input: LMInput(tokens: MLXArray(tokens[0..<fed].map(Int32.init))), model: draft.model,
                                      cache: draftKV, parameters: params)
            }
            do {
                generation = try MLXLMCommon.generate(input: rest, cache: kv, state: state, parameters: params, context: ctx,
                                                      draftModel: draft.model, draftCache: draftKV, numDraftTokens: 3, tools: tools)
                drafted = true
            } catch where "\(error)".contains("requires trimmable KV caches") {
                // The iterator checks this before touching either cache, so `kv` is as it was: decode without the
                // draft rather than fail the request. (The library's error type is internal, hence the message match.)
                generation = try MLXLMCommon.generate(input: rest, cache: kv, state: state, parameters: params, context: ctx, tools: tools)
            }
        } else {
            generation = try MLXLMCommon.generate(input: rest, cache: kv, state: state, parameters: params, context: ctx, tools: tools)
        }
        var started = Started(generation: generation, promptTokens: tokens.count, cachedTokens: hit?.reused ?? 0)
        started.drafted = drafted
        if let boundary {
            let prefix = Array(tokens[0..<boundary])
            started.afterward = { await cache.persist(prefix) }
        }
        return started
    }

    /// Holds the GPU gate from prefill to the end of generation and turns MLX events into `ChatEvent`s.
    private func run(lease: ModelLease<ModelContainer>, draftLease: ModelLease<ModelContainer>?, stripThinking: Bool,
                     progress: Progress, start: () async throws -> Started) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        await GPUGate.shared.acquire()
        let releaseGate = GateRelease()
        let started: Started
        do {
            // Prefill happens inside start(), before it returns the token stream.
            progress(.promptStarted)
            started = try await start()
            progress(.promptDone)
        } catch {
            releaseGate()
            lease.release()
            draftLease?.release()
            throw error
        }
        let generation = started.generation, promptTokens = started.promptTokens, cachedTokens = started.cachedTokens
        let afterward = started.afterward, drafted = started.drafted

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
                        // info counts only the tokens fed after the cached prefix.
                        var usage = ChatUsage(promptTokens: promptTokens, completionTokens: info.generationTokenCount,
                                              cachedTokens: cachedTokens)
                        usage.drafted = drafted
                        continuation.yield(.done(finishReason: reason, usage: usage))
                    case .toolCall(let call):
                        let args = (try? JSONEncoder().encode(call.function.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        continuation.yield(.toolCall(name: call.function.name, arguments: args))
                    default:
                        break
                    }
                }
                // The reply is complete (`.done` is out); a cancelled request has already released the gate.
                if !Task.isCancelled { await afterward?() }
                releaseGate()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                releaseGate()
                lease.release()
                draftLease?.release()
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
            case .progress: break
            }
        }
        return ChatResult(modelID: spec.id, text: text, toolCalls: calls, finishReason: finish, usage: usage)
    }

    /// Prompt tokens for `messages` after the chat template (and image tokens), without generating.
    public func countTokens(model spec: ModelSpec, messages: [ChatMessage], options: ChatOptions) async throws -> Int {
        guard !messages.isEmpty else { throw ChatError.emptyConversation }
        guard spec.engine != .mlxvlm, spec.engine != .gguf else {
            throw EngineError.unsupported("Token counting is not available for mlx-vlm or GGUF models.")
        }
        let lease = try await containerLease(for: spec, progress: { _ in })
        defer { lease.release() }
        let container = lease.value
        return try await GPUGate.shared.run {
            try await container.prepare(input: try Self.userInput(messages, options)).text.tokens.size
        }
    }

    /// Bytes of the loaded weights (quantized tensors count at their packed size).
    static func weightBytes(_ container: ModelContainer) async -> Int {
        await container.perform { ctx in ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes } }
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

    /// The draft model for `spec`, if one is set and downloaded. It loads text-only (MLXLLM), so it carries no
    /// vision state into its cache, and it is leased like any model, so it counts toward the memory budget.
    private func draftLease(for spec: ModelSpec, progress: @escaping Progress) async throws -> ModelLease<ModelContainer>? {
        guard let id = draftModels[spec.id], let draft = Catalog.spec(id),
              let folder = await store.folder(for: id) else { return nil }
        return try await models.lease("draft:\(id)", as: ModelContainer.self, estimatedBytes: draft.estimatedResidentBytes,
                                      measure: { await Self.weightBytes($0) }) {
            try await Self.timed(progress) {
                (try await LLMModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader()), unload: {})
            }
        }
    }

    private func containerLease(for spec: ModelSpec, progress: @escaping Progress) async throws -> ModelLease<ModelContainer> {
        guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        let cache = promptCache(spec.id, folder: folder)
        return try await models.lease(spec.id, as: ModelContainer.self, estimatedBytes: spec.estimatedResidentBytes,
                                      measure: { await Self.weightBytes($0) + cache.stats.bytes }) {
            try await Self.timed(progress) {
            // Vision-language architectures load through MLXVLM; text-only ones (Llama, Mistral, ... added from
            // Hugging Face) are only in MLXLLM's registry.
            let config = (try? Data(contentsOf: folder.appending(path: "config.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let modelType = config?["model_type"] as? String
            let vlm: Bool
            if let modelType { vlm = await VLMTypeRegistry.shared.contains(modelType) } else { vlm = true }
            let container = vlm
                ? try await VLMModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader())
                : try await LLMModelFactory.shared.loadContainer(from: folder, using: TransformersTokenizerLoader())
            return (container, unload: { await cache.clear() })
        } }
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

    /// The tokens the chat template appends to open the assistant's turn (Qwen3.5 with thinking off:
    /// `<|im_start|>assistant\n<think>\n\n</think>\n\n`), found by rendering a probe with and without it.
    /// Nil when the template does not render the probe as prefix plus suffix.
    func generationPrompt(context: [String: any Sendable]?) -> [Int]? {
        let probe: [[String: any Sendable]] = [["role": "user", "content": "x"]]
        guard let with = try? upstream.applyChatTemplate(messages: probe, chatTemplate: nil, addGenerationPrompt: true,
                                                         truncation: false, maxLength: nil, tools: nil, additionalContext: context),
              let without = try? upstream.applyChatTemplate(messages: probe, chatTemplate: nil, addGenerationPrompt: false,
                                                            truncation: false, maxLength: nil, tools: nil, additionalContext: context),
              with.count > without.count, Array(with.prefix(without.count)) == without
        else { return nil }
        return Array(with.dropFirst(without.count))
    }

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
