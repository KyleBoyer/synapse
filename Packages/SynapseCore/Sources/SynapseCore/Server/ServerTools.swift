import CoreLocation
import Foundation
import Hummingbird

// Tools Synapse runs itself during a chat, as OpenAI's hosted tools and Anthropic's server tools do: the model calls
// one, Synapse runs it, hands the result back to the model and lets it continue. The client sees each call as an item
// (web_search_call, image_generation_call, ...) and only the model's final answer as text.
//
// Request tool types: `web_search` (also `web_search_preview*`, Anthropic's `web_search_2025…`), `image_generation`,
// and Synapse's own `synapse` (date and time, the model catalog, what is loaded). Chat Completions' `web_search_options`
// turns on web search too.

/// The built-in tools a request turned on.
struct ServerTools: Sendable {
    var webSearch = false
    /// Reading a page; on with web search, or alone (Anthropic's web_fetch_*).
    var webFetch = false
    /// image_generation came from the settings, not the request: dropped when no image model is downloaded.
    var imageFromSettings = false
    /// Anthropic's max_uses; nil is no limit beyond the loop's rounds.
    var maxSearches: Int?
    var image: ImageToolConfig?
    var synapse = false
    /// generate_speech, generate_sound (audio_generation) and generate_video (video_generation): Synapse's own.
    var speech = false, sound = false, video = false
    /// Which of those came from the settings rather than the request: dropped when no model for them is downloaded.
    var mediaFromSettings = false
    /// The app's tool settings: search provider, image model and size defaults, rounds.
    var settings = ToolSettings()

    var isEmpty: Bool { !webSearch && !webFetch && image == nil && !synapse && !speech && !sound && !video }

    static func isServerType(_ type: String) -> Bool {
        type == "web_search" || type.hasPrefix("web_search_") || type == "web_fetch" || type.hasPrefix("web_fetch_")
            || type == "image_generation" || type == "synapse" || type == "audio_generation" || type == "video_generation"
    }

    /// Splits a request's tools into Synapse's own and the rest, which stay the client's function tools. The settings
    /// fill in what the request leaves out (image model and size) and add the tools turned on for every request.
    static func split(_ tools: [JSONValue]?, settings: ToolSettings = ToolSettings()) throws -> (ServerTools, [JSONValue]) {
        var server = ServerTools(settings: settings), rest: [JSONValue] = []
        for t in tools ?? [] {
            let type = t["type"]?.string ?? ""
            if type == "web_search" || type.hasPrefix("web_search_") {
                guard settings.searchProvider != .off else { throw ChatParse.bad("Web search is turned off in Synapse's settings (Server → Built-in tools).") }
                server.webSearch = true
                server.webFetch = true
                server.maxSearches = t["max_uses"]?.number.map(Int.init)
            } else if type == "web_fetch" || type.hasPrefix("web_fetch_") {
                server.webFetch = true
            } else if type == "image_generation" {
                server.image = try ImageToolConfig(t)
            } else if type == "synapse" {
                server.synapse = true
            } else if type == "audio_generation" {
                server.speech = true; server.sound = true
            } else if type == "video_generation" {
                server.video = true
            } else {
                rest.append(t)
            }
        }
        if settings.alwaysOn.contains(.webSearch), settings.searchProvider != .off { server.webSearch = true; server.webFetch = true }
        if settings.alwaysOn.contains(.imageGeneration), server.image == nil {
            server.image = try ImageToolConfig(.object([:]))
            server.imageFromSettings = true
        }
        if settings.alwaysOn.contains(.synapse) { server.synapse = true }
        if settings.alwaysOn.contains(.audioGeneration), !server.speech {
            server.speech = true; server.sound = true; server.mediaFromSettings = true
        }
        if settings.alwaysOn.contains(.videoGeneration), !server.video { server.video = true; server.mediaFromSettings = true }
        if var image = server.image {
            image.model = image.model ?? settings.imageModel
            image.size = image.size ?? settings.imageSize
            server.image = image
        }
        return (server, rest)
    }

    /// The functions the model is offered for these tools.
    var functions: [ChatTool] {
        var out: [ChatTool] = []
        if webSearch { out.append(ServerToolKind.webSearch.function) }
        if webFetch { out.append(ServerToolKind.webFetch.function) }
        if image != nil { out.append(ServerToolKind.image.function) }
        if speech { out.append(ServerToolKind.speech.function) }
        if sound { out.append(ServerToolKind.sound.function) }
        if video { out.append(ServerToolKind.video.function) }
        if synapse { out += ServerToolKind.synapseSet.map(\.function) }
        return out
    }

    func kind(of name: String) -> ServerToolKind? {
        guard let kind = ServerToolKind(rawValue: name) else { return nil }
        switch kind {
        case .webSearch: return webSearch ? kind : nil
        case .webFetch: return webFetch ? kind : nil
        case .image: return image != nil ? kind : nil
        case .speech: return speech ? kind : nil
        case .sound: return sound ? kind : nil
        case .video: return video ? kind : nil
        case .time, .dates, .calculate, .models, .status: return synapse ? kind : nil
        }
    }
}

/// A built-in tool, by the function name the model calls.
enum ServerToolKind: String, Sendable {
    case webSearch = "web_search", webFetch = "web_fetch", image = "generate_image"
    case speech = "generate_speech", sound = "generate_sound", video = "generate_video"
    case time = "synapse_time", dates = "date_difference", calculate = "calculate", models = "synapse_models", status = "synapse_status"

    /// The `synapse` tool type's functions.
    static let synapseSet: [ServerToolKind] = [.time, .dates, .calculate, .models, .status]
    var isSynapse: Bool { Self.synapseSet.contains(self) }

    var function: ChatTool {
        let none = #"{"type":"object","properties":{}}"#
        switch self {
        case .webSearch:
            return ChatTool(name: rawValue, description: "Search the web. Use it for current events, facts you are unsure of, and anything after your training. Returns titles, links and snippets.",
                            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"What to search for"}},"required":["query"]}"#)
        case .image:
            return ChatTool(name: rawValue, description: "Create or edit an image. Call this whenever the user asks for a picture, drawing, photo or image edit. The image is shown to the user.",
                            parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed description of the image to create: subject, setting, style, lighting"}},"required":["prompt"]}"#)
        case .speech:
            return ChatTool(name: rawValue, description: "Read text aloud as speech: narration, a voice message, a pronunciation. The audio is linked for the user.",
                            parametersJSON: #"{"type":"object","properties":{"text":{"type":"string","description":"The exact words to speak"},"voice":{"type":"string","description":"Optional voice name"}},"required":["text"]}"#)
        case .sound:
            return ChatTool(name: rawValue, description: "Make music or a sound effect from a description. The audio is linked for the user.",
                            parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string","description":"The sound or music: style, instruments, mood, tempo"},"seconds":{"type":"number","description":"Length in seconds (default 8)"},"lyrics":{"type":"string","description":"Optional lyrics to sing, for music models that sing"}},"required":["prompt"]}"#)
        case .video:
            return ChatTool(name: rawValue, description: "Start making a short video clip from a description. It renders in the background for several minutes; the user gets a link that works once it is done.",
                            parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed description of the clip: subject, motion, camera, setting, style"},"seconds":{"type":"integer","description":"4, 8 or 12 (default 4)"}},"required":["prompt"]}"#)
        case .webFetch:
            return ChatTool(name: rawValue, description: "Read a web page's text, e.g. a search result, to answer from the page itself.",
                            parametersJSON: #"{"type":"object","properties":{"url":{"type":"string","description":"The http(s) address to read"}},"required":["url"]}"#)
        case .time:
            return ChatTool(name: rawValue, description: "The current date, time and weekday, here or in another time zone or city.",
                            parametersJSON: #"{"type":"object","properties":{"time_zone":{"type":"string","description":"Optional: an IANA zone (Asia/Tokyo), abbreviation (PST) or city (Tokyo). Leave out for the user's own."}}}"#)
        case .dates:
            return ChatTool(name: rawValue, description: "Date arithmetic: the days and weeks between two dates, or the date some days before or after one. Dates are YYYY-MM-DD; a missing date is today.",
                            parametersJSON: #"{"type":"object","properties":{"from":{"type":"string","description":"Start date, YYYY-MM-DD (default today)"},"to":{"type":"string","description":"End date, YYYY-MM-DD"},"add_days":{"type":"integer","description":"Days to add to from (negative to go back)"}}}"#)
        case .calculate:
            return ChatTool(name: rawValue, description: "Evaluate arithmetic exactly instead of working it out: + - * / % ^, parentheses, sqrt, abs, round, floor, ceil, ln, log, log2, exp, sin, cos, tan, asin, acos, atan, min, max, pow, pi, e.",
                            parametersJSON: #"{"type":"object","properties":{"expression":{"type":"string","description":"For example (17.5 * 12) / 3 + sqrt(2)"}},"required":["expression"]}"#)
        case .models:
            return ChatTool(name: rawValue, description: "The AI models installed in Synapse, the app running you: what each one does, its size, and which are loaded.", parametersJSON: none)
        case .status:
            return ChatTool(name: rawValue, description: "Synapse's version, this Mac's memory, and the models loaded in memory now with how much each uses and when it loaded.", parametersJSON: none)
        }
    }

    /// Output item id prefix, as OpenAI's (ws_, ig_); st_ for Synapse's own.
    var idPrefix: String {
        switch self {
        case .webSearch, .webFetch: "ws_"
        case .image: "ig_"
        case .speech, .sound: "au_"
        case .video: "vg_"
        case .time, .dates, .calculate, .models, .status: "st_"
        }
    }
}

struct WebResult: Sendable, Equatable, Encodable {
    var title: String
    var url: String
    var snippet: String
}

/// Audio made, or a video started, by a built-in tool; served from Synapse's own links.
struct GeneratedMedia: Sendable {
    enum Kind: String, Sendable { case audio, video }
    var kind: Kind
    var prompt: String
    var url: String
    var jobID: String? = nil
}

struct GeneratedImage: Sendable {
    var prompt: String
    var data: Data           // encoded in `format`
    var format: String
    var size: String
    var quality: String
    var action: String
    var url: String?         // served from /v1/images/files, for clients that show markdown
}

/// One built-in tool call, as it runs and once it finished.
struct ServerToolCall: Sendable {
    enum Output: Sendable {
        case search(query: String, results: [WebResult])
        case image(GeneratedImage)
        case page(WebPage)
        case media(GeneratedMedia)
        case info(String)     // JSON text
    }
    var id: String
    var kind: ServerToolKind
    var arguments: String
    var output: Output?
    var error: String?

    var argumentsObject: [String: JSONValue] {
        if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)) { return o }
        return [:]
    }
    var query: String { argumentsObject["query"]?.string ?? "" }

    /// What the model reads back.
    var forModel: String {
        if let error { return "Error: \(error)" }
        switch output {
        case .search(_, let results)?:
            if results.isEmpty { return "No results." }
            return results.enumerated().map { "\($0 + 1). \($1.title)\n\($1.url)\n\($1.snippet)" }.joined(separator: "\n\n")
        case .page(let p)?: return "\(p.title)\n\(p.url)\n\n\(p.text)"
        case .image?: return "The image was created and is shown to the user. Do not repeat it as a link."
        case .media(let m)? where m.kind == .video:
            return "The video is rendering now (job \(m.jobID ?? "")); it takes several minutes. The user has a link that works once it is done. Tell them it is on its way; do not wait for it or repeat the link."
        case .media?: return "The audio was created and is linked for the user. Do not repeat the link."
        case .info(let json)?: return json
        case nil: return ""
        }
    }
}

enum ToolLoopEvent: Sendable {
    case chat(ChatEvent)
    case toolStarted(ServerToolCall)
    case toolFinished(ServerToolCall)
}

/// Runs built-in tools for one request.
struct ServerToolRunner: Sendable {
    typealias Generate = @Sendable ([ChatMessage], ChatOptions) async throws -> AsyncThrowingStream<ChatEvent, Error>
    typealias Execute = @Sendable (ServerToolCall, [ChatMessage]) async -> ServerToolCall

    var tools: ServerTools
    /// Model turns; after this many the tools are taken away so the model answers.
    var maxRounds = 5

    /// A turn's options: the built-in functions ahead of the client's, except on the last turn.
    func options(_ options: ChatOptions, round: Int) -> ChatOptions {
        var o = options
        if round < maxRounds { o.tools = tools.functions + options.tools }
        return o
    }

    /// The chat with built-in tools: model turns alternate with tool runs until the model answers or calls a client tool.
    /// Usage is summed over the turns. A turn that calls both kinds hands the client its calls and skips the built-ins.
    /// `first`: the first turn, already started with `options(for: 1)`, so load errors reach the client before a stream opens.
    func stream(messages: [ChatMessage], options: ChatOptions, first: AsyncThrowingStream<ChatEvent, Error>? = nil,
                generate: @escaping Generate, execute: @escaping Execute) -> AsyncThrowingStream<ToolLoopEvent, Error> {
        let tools = self.tools, maxRounds = self.maxRounds, runner = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var conversation = messages
                    var total = ChatUsage(promptTokens: 0, completionTokens: 0)
                    var searches = 0
                    for round in 1...maxRounds {
                        let events: AsyncThrowingStream<ChatEvent, Error>
                        if round == 1, let first { events = first } else {
                            events = try await generate(conversation, runner.options(options, round: round))
                        }
                        var text = "", builtin: [ServerToolCall] = [], clientCalls = false
                        var finish = "stop"
                        for try await e in events {
                            switch e {
                            case .toolCall(let name, let arguments):
                                if let kind = tools.kind(of: name) {
                                    builtin.append(ServerToolCall(id: kind.idPrefix + newServerToolID(), kind: kind, arguments: arguments))
                                } else {
                                    clientCalls = true
                                    continuation.yield(.chat(e))
                                }
                            case .done(let f, let u):
                                finish = f
                                total.promptTokens += u.promptTokens
                                total.completionTokens += u.completionTokens
                                total.cachedTokens += u.cachedTokens
                                total.drafted = total.drafted || u.drafted
                            case .delta(let s):
                                text += s
                                continuation.yield(.chat(e))
                            case .reasoning, .progress:
                                continuation.yield(.chat(e))
                            }
                        }
                        // shortcut: built-in calls beside client calls are dropped; run them first if a model ever mixes the two.
                        // On the last turn the tools are gone, so a call the model makes anyway is dropped and the answer ends.
                        guard !builtin.isEmpty, !clientCalls, round < maxRounds else {
                            continuation.yield(.chat(.done(finishReason: finish, usage: total)))
                            continuation.finish()
                            return
                        }
                        conversation.append(ChatMessage(role: .assistant, text: (text.isEmpty ? "" : text + "\n") +
                            builtin.map { ToolMarkup.call(name: $0.kind.rawValue, argumentsJSON: $0.arguments) }.joined(separator: "\n")))
                        var results: [String] = []
                        for var call in builtin {
                            continuation.yield(.toolStarted(call))
                            if call.kind == .webSearch, let max = tools.maxSearches, searches >= max {
                                call.error = "The search limit for this request is reached; answer with what you have."
                            } else {
                                if call.kind == .webSearch { searches += 1 }
                                call = await execute(call, conversation)
                            }
                            continuation.yield(.toolFinished(call))
                            results.append(ToolMarkup.response(call.forModel))
                        }
                        // Otherwise a model that keeps calling (a search that keeps failing) ends on a turn without tools and
                        // often says nothing; Synapse's own tool result tells it this is the last one.
                        if round == maxRounds - 1 {
                            results.append(ToolMarkup.response("No more tool calls are available for this answer. Answer now with what you have."))
                        }
                        try Task.checkCancellation()
                        conversation.append(ChatMessage(role: .user, text: results.joined(separator: "\n")))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Starts a chat with `tools` on `spec`; `wrap` post-processes each model turn (stop sequences).
func chatWithServerTools(_ tools: ServerTools, services: ServerToolServices, spec: ModelSpec, messages: [ChatMessage],
                         options: ChatOptions,
                         wrap: @escaping @Sendable (AsyncThrowingStream<ChatEvent, Error>) -> AsyncThrowingStream<ChatEvent, Error> = { $0 })
    async throws -> AsyncThrowingStream<ToolLoopEvent, Error> {
    var tools = tools
    if tools.imageFromSettings, (try? await services.images.resolve(tools.image?.model, edit: false)) == nil { tools.image = nil }
    if tools.mediaFromSettings {
        if tools.speech, (try? await services.speech.resolve(model: nil)) == nil { tools.speech = false }
        if tools.sound, (try? await services.sound.resolve(nil)) == nil { tools.sound = false }
        if tools.video, (try? await services.videos.resolve(nil)) == nil { tools.video = false }
    }
    let runner = ServerToolRunner(tools: tools, maxRounds: min(max(tools.settings.maxRounds, 2), 10))
    let chat = services.chat
    let first = wrap(try await chat.stream(model: spec, messages: messages, options: runner.options(options, round: 1)))
    return runner.stream(messages: messages, options: options, first: first,
                         generate: { wrap(try await chat.stream(model: spec, messages: $0, options: $1)) },
                         execute: { await services.execute($0, $1) })
}

func newServerToolID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

/// What built-in tools run on, made once with the router; `services` binds them to one request.
struct ToolBackends: Sendable {
    var chat: ChatService
    var images: ImageService
    var speech: SpeechService
    var sound: SoundService
    var videos: VideoService
    var store: ModelStore
    var files: ImageFileCache

    func services(_ req: Request, _ ctx: SynapseContext, _ tools: ServerTools) -> ServerToolServices {
        ServerToolServices(chat: chat, images: images, speech: speech, sound: sound, videos: videos, store: store, files: files,
                           fileBase: imageFileBase(req, ctx), tools: tools)
    }
}

/// The services built-in tools use.
struct ServerToolServices: Sendable {
    var chat: ChatService
    var images: ImageService
    var speech: SpeechService
    var sound: SoundService
    var videos: VideoService
    var store: ModelStore
    var files: ImageFileCache
    /// Base for image URLs: http://host/[k/key/]v1/images/files/
    var fileBase: String
    var tools: ServerTools

    func execute(_ call: ServerToolCall, _ conversation: [ChatMessage]) async -> ServerToolCall {
        var call = call
        do {
            switch call.kind {
            case .webSearch:
                let query = call.query
                guard !query.isEmpty else { throw ChatParse.bad("web_search needs a query.") }
                call.output = .search(query: query, results: try await WebSearch.search(query, settings: tools.settings))
            case .image:
                call.output = .image(try await drawImage(call.argumentsObject["prompt"]?.string ?? "", conversation))
            case .speech:
                call.output = .media(try await speak(call.argumentsObject))
            case .sound:
                call.output = .media(try await makeSound(call.argumentsObject))
            case .video:
                call.output = .media(try await startVideo(call.argumentsObject))
            case .webFetch:
                call.output = .page(try await WebFetch.fetch(call.argumentsObject["url"]?.string ?? ""))
            case .time:
                call.output = .info(try await SynapseInfo.time(in: call.argumentsObject["time_zone"]?.string))
            case .dates:
                let a = call.argumentsObject
                call.output = .info(try SynapseInfo.dates(from: a["from"]?.string, to: a["to"]?.string, addDays: (a["add_days"]?.number ?? a["add_days"]?.string.flatMap(Double.init)).map(Int.init)))
            case .calculate:
                call.output = .info(try Calculator.answer(call.argumentsObject["expression"]?.string ?? ""))
            case .models:
                call.output = .info(await SynapseInfo.models(store: store, chat: chat))
            case .status:
                call.output = .info(await SynapseInfo.status(chat: chat))
            }
        } catch {
            call.error = (error as? HTTPError)?.body ?? error.localizedDescription
        }
        return call
    }

    /// The model picked in settings while it is still downloaded; nil (the lightest) once it has been deleted.
    private func chosen(_ id: String?) async -> String? {
        guard let id, !id.isEmpty else { return nil }
        return await store.downloaded.contains(id) ? id : nil
    }

    /// With no model named in the request or settings: the fast models first (FLUX.2 klein 4B draws 1024 × 1024 in about
    /// 80 s on 16 GB), not the smallest download, which is Qwen-Image 4-bit and takes many minutes there. nil leaves it
    /// to ImageService (the smallest downloaded).
    static func preferredImageModel(_ downloaded: Set<String>, edit: Bool) -> String? {
        (edit ? ["flux2-klein-4b", "flux2-klein-9b"] : ["flux2-klein-4b", "z-image-turbo", "flux2-klein-9b"]).first(where: downloaded.contains)
    }

    private func speak(_ a: [String: JSONValue]) async throws -> GeneratedMedia {
        guard let text = a["text"]?.string, !text.isEmpty else { throw ChatParse.bad("generate_speech needs text.") }
        let model = try await speech.resolve(model: await chosen(tools.settings.speechModel))
        let (rate, pcm) = try await speech.synthesize(model: model, text: String(text.prefix(SpeechService.maxInputCharacters)),
                                                      voice: a["voice"]?.string, speed: 1)
        var data = Data()
        for try await chunk in speech.encoder.encode(pcm, sampleRate: rate, as: .mp3) { data.append(chunk) }
        return GeneratedMedia(kind: .audio, prompt: text, url: fileBase + (await files.put(data, ext: "mp3", mime: "audio/mpeg")))
    }

    private func makeSound(_ a: [String: JSONValue]) async throws -> GeneratedMedia {
        guard let prompt = a["prompt"]?.string, !prompt.isEmpty else { throw ChatParse.bad("generate_sound needs a prompt.") }
        let seconds = min(max(a["seconds"]?.number ?? a["seconds"]?.string.flatMap(Double.init) ?? 8, 1), SoundService.maxSeconds)
        let model = try await sound.resolve(await chosen(tools.settings.soundModel))
        let clip = try await sound.generate(model: model, prompt: prompt, lyrics: a["lyrics"]?.string, seconds: seconds, seed: nil)
        let data = try await sound.encoded(clip, as: .mp3)
        return GeneratedMedia(kind: .audio, prompt: prompt, url: fileBase + (await files.put(data, ext: "mp3", mime: "audio/mpeg")))
    }

    /// Queues the clip and returns at once: a render takes minutes, longer than chat apps wait for a reply.
    private func startVideo(_ a: [String: JSONValue]) async throws -> GeneratedMedia {
        guard let prompt = a["prompt"]?.string, !prompt.isEmpty else { throw ChatParse.bad("generate_video needs a prompt.") }
        let requested = Int(a["seconds"]?.number ?? a["seconds"]?.string.flatMap(Double.init) ?? 4)
        let seconds = [4, 8, 12].min { abs($0 - requested) < abs($1 - requested) }!
        let model = try await videos.resolve(await chosen(tools.settings.videoModel))
        let job = await videos.create(model: model, request: VideoRequest(prompt: prompt, width: 768, height: 512,
                                                                          frames: VideoService.frames(seconds: seconds), seed: nil,
                                                                          inputImage: nil, loras: []), size: "768x512")
        let videosBase = fileBase.replacingOccurrences(of: "images/files/", with: "videos/")
        return GeneratedMedia(kind: .video, prompt: prompt, url: videosBase + job.id + "/content", jobID: job.id)
    }

    private func drawImage(_ prompt: String, _ conversation: [ChatMessage]) async throws -> GeneratedImage {
        guard let config = tools.image else { throw ChatParse.bad("image_generation is not on.") }
        let prompt = prompt.isEmpty ? conversation.last(where: { $0.role == .user })?.text ?? "" : prompt
        let sources = conversation.last(where: { $0.role == .user && !$0.images.isEmpty })?.images ?? []
        let edit = config.action == "edit" || (config.action == "auto" && !sources.isEmpty)
        let downloaded = await store.downloaded
        let spec = try await images.resolve(await chosen(config.model) ?? Self.preferredImageModel(downloaded, edit: edit), edit: edit)
        let (width, height) = try ImageService.parseSize(config.size)
        let request = ImageRequest(prompt: prompt, width: width, height: height, inputImages: edit ? sources : [])
        let png = try await images.generate(model: spec, request: request, count: 1) { _, _ in }[0]
        let data = try ImageEncoding.encode(png, format: config.outputFormat, compression: config.outputCompression)
        let mime = config.outputFormat == "jpeg" ? "image/jpeg" : "image/\(config.outputFormat)"
        let name = await files.put(data, ext: config.outputFormat, mime: mime)
        return GeneratedImage(prompt: prompt, data: data, format: config.outputFormat, size: "\(width)x\(height)",
                              quality: config.quality == "auto" ? "medium" : config.quality, action: edit ? "edit" : "generate",
                              url: fileBase + name)
    }
}

// MARK: Web search

/// Web search through the provider chosen in settings. The query (written by the model) goes to that provider.
enum WebSearch {
    static func search(_ query: String, settings: ToolSettings) async throws -> [WebResult] {
        let count = min(max(settings.searchResults, 1), 20)
        let key = settings.searchKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch settings.searchProvider {
        case .off:
            throw SearchError("Web search is turned off in Synapse's settings.")
        case .duckDuckGo:
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "q", value: query)]
            var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            return Array(parse(String(decoding: try await fetch(req), as: UTF8.self)).prefix(count))
        case .brave:
            guard !key.isEmpty else { throw SearchError("Brave Search needs an API key in Synapse's settings.") }
            var u = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            u.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(count))]
            var req = URLRequest(url: u.url!, timeoutInterval: 15)
            req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            return results(try await fetch(req), list: ["web", "results"], snippet: "description", count: count)
        case .tavily:
            guard !key.isEmpty else { throw SearchError("Tavily needs an API key in Synapse's settings.") }
            var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "max_results": count])
            return results(try await fetch(req), list: ["results"], snippet: "content", count: count)
        case .searxng:
            guard let base = settings.searxngURL.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                  ["http", "https"].contains(base.scheme ?? "") else {
                throw SearchError("SearXNG needs its address in Synapse's settings, e.g. http://localhost:8080.")
            }
            var u = URLComponents(url: base.appending(path: "search"), resolvingAgainstBaseURL: false)!
            u.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
            return results(try await fetch(URLRequest(url: u.url!, timeoutInterval: 15)), list: ["results"], snippet: "content", count: count)
        }
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        var req = request
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // DuckDuckGo answers 202 with a bot check when one address searches a lot.
        if status == 202, req.url?.host()?.hasSuffix("duckduckgo.com") == true {
            throw SearchError("DuckDuckGo is limiting searches from this Mac for now. Try again in a few minutes, or choose Brave Search, Tavily or SearXNG in Synapse's settings (Server → Built-in tools).")
        }
        guard status == 200 else { throw SearchError("The search service answered HTTP \(status) (\(req.url?.host() ?? "")).") }
        return data
    }

    /// JSON APIs: a list of {title, url, <snippet>} objects at `list`.
    static func results(_ data: Data, list: [String], snippet: String, count: Int) -> [WebResult] {
        var node: Any? = try? JSONSerialization.jsonObject(with: data)
        for key in list { node = (node as? [String: Any])?[key] }
        return ((node as? [[String: Any]]) ?? []).prefix(count).compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            return WebResult(title: text(r["title"] as? String ?? url), url: url, snippet: text(r[snippet] as? String ?? ""))
        }
    }

    struct SearchError: LocalizedError { let errorDescription: String?; init(_ m: String) { errorDescription = m } }

    /// Result links and snippets, in page order; ads (links through duckduckgo.com) are skipped.
    static func parse(_ html: String) -> [WebResult] {
        let links = html.matches(of: /class="result__a" href="([^"]+)"[^>]*>(.*?)<\/a>/.dotMatchesNewlines())
        var out: [WebResult] = []
        for (i, link) in links.enumerated() {
            var url = String(link.1)
            if url.hasPrefix("//") { url = "https:" + url }
            // Older pages wrap the target as /l/?uddg=<url>.
            if let wrapped = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "uddg" })?.value { url = wrapped }
            guard !url.contains("duckduckgo.com/") else { continue }
            // The result's snippet sits between its link and the next result's.
            let rest = html[link.range.upperBound..<(i + 1 < links.count ? links[i + 1].range.lowerBound : html.endIndex)]
            let snippet = rest.firstMatch(of: /class="result__snippet"[^>]*>(.*?)<\/a>/.dotMatchesNewlines()).map { text(String($0.1)) } ?? ""
            out.append(WebResult(title: text(String(link.2)), url: url, snippet: snippet))
        }
        return out
    }

    static func text(_ html: String) -> String {
        var s = html.replacing(/<[^>]+>/, with: "")
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Synapse's own tools

enum SynapseInfo {
    static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// `name`: an IANA id, an abbreviation, or a city in one (Tokyo, New York); nil is this Mac's zone.
    static func time(in name: String?) async throws -> String {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return time() }
        guard let zone = await zone(lookingUp: name) else {
            throw ChatParse.bad("No time zone found for '\(name)'. Call again with the IANA time zone for that place, such as America/Chicago or Europe/Paris.")
        }
        return time(zone: zone, place: zone.identifier.lowercased().hasSuffix(name.lowercased().replacingOccurrences(of: " ", with: "_")) ? nil : name)
    }

    /// An IANA id, abbreviation or zone city first; otherwise any place, through macOS's geocoder (Apple's service).
    static func zone(lookingUp name: String) async -> TimeZone? {
        if let z = zone(named: name) { return z }
        let placemarks = try? await withThrowingTaskGroup(of: [CLPlacemark]?.self) { group in
            group.addTask { try await CLGeocoder().geocodeAddressString(name) }
            group.addTask { try await Task.sleep(for: .seconds(8)); return nil }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        return placemarks?.first?.timeZone
    }

    static func zone(named name: String) -> TimeZone? {
        if let z = TimeZone(identifier: name) ?? TimeZone(abbreviation: name.uppercased()) { return z }
        let city = name.replacingOccurrences(of: " ", with: "_").lowercased()
        return TimeZone.knownTimeZoneIdentifiers.first { $0.lowercased().hasSuffix("/" + city) }.flatMap(TimeZone.init(identifier:))
    }

    /// Days between two dates, or `from` moved by `addDays`, in this Mac's calendar.
    static func dates(from: String?, to: String?, addDays: Int?, today: Date = Date(), zone: TimeZone = .current) throws -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = zone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let weekday = DateFormatter()
        weekday.calendar = cal; weekday.timeZone = zone; weekday.locale = Locale(identifier: "en_US_POSIX"); weekday.dateFormat = "EEEE"
        func day(_ s: String?) throws -> Date {
            guard let s, !s.isEmpty else { return cal.startOfDay(for: today) }
            guard let d = f.date(from: String(s.prefix(10))) else { throw ChatParse.bad("Dates are YYYY-MM-DD; got '\(s)'.") }
            return d
        }
        let start = try day(from)
        // `to` wins when a model sends both (small models add a guessed add_days to a difference question).
        if let addDays, to?.isEmpty != false {
            guard let d = cal.date(byAdding: .day, value: addDays, to: start) else { throw ChatParse.bad("add_days is out of range.") }
            return json(["from": f.string(from: start), "add_days": addDays, "date": f.string(from: d), "weekday": weekday.string(from: d)])
        }
        guard to?.isEmpty == false else { throw ChatParse.bad("Give `to` (a date) or `add_days`.") }
        let end = try day(to)
        let days = cal.dateComponents([.day], from: start, to: end).day ?? 0
        return json(["from": f.string(from: start), "to": f.string(from: end), "days": days,
                     "weeks_and_days": "\(days / 7) weeks \(days % 7) days", "from_weekday": weekday.string(from: start),
                     "to_weekday": weekday.string(from: end)])
    }

    static func time(now: Date = Date(), zone: TimeZone = .current, place: String? = nil) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = zone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        var o: [String: Any] = ["now": iso.string(from: now), "readable": f.string(from: now), "time_zone": zone.identifier,
                                "utc_offset_hours": Double(zone.secondsFromGMT(for: now)) / 3600, "unix": Int(now.timeIntervalSince1970)]
        if let place { o["place"] = place }
        return json(o)
    }

    static func models(store: ModelStore, chat: ChatService) async -> String {
        let loaded = Set(await chat.models.residents().map(\.id))
        let installed = await store.downloaded.sorted().compactMap { id -> [String: Any]? in
            guard let spec = Catalog.spec(id) else { return nil }
            let facts = ModelFacts(id: id, spec: spec)
            return ["id": id, "name": spec.displayName, "kind": facts.kind, "download_gb": Double(spec.approxMB) / 1000,
                    "loaded": loaded.contains(id)]
        }
        return json(["installed": installed, "catalog_size": Catalog.all.count])
    }

    // shortcut: lists the chat model manager's residents, which in the app is shared by every model kind.
    static func status(chat: ChatService) async -> String {
        let residents = await chat.models.residents()
        let now = Date()
        let loaded = residents.map { r -> [String: Any] in
            ["id": r.id, "memory_gb": (Double(r.bytes) / 1e9 * 10).rounded() / 10, "measured": r.measured,
             "loaded_seconds_ago": Int(now.timeIntervalSince(r.loadedAt)), "idle_seconds": Int(now.timeIntervalSince(r.lastUsed)),
             "in_use": r.leases > 0]
        }
        return json(["version": Synapse.version, "mac_memory_gb": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                     "loaded_models": loaded,
                     "loaded_memory_gb": (Double(residents.reduce(0) { $0 + $1.bytes }) / 1e9 * 10).rounded() / 10])
    }
}

// MARK: Calculator

/// Arithmetic for the `calculate` tool: a small recursive-descent parser over Double. It evaluates nothing but the
/// operators, functions and constants below, so a model's input can't run code.
struct Calculator {
    struct Failure: LocalizedError { let errorDescription: String? }

    private let chars: [Character]
    private var i = 0

    static func answer(_ expression: String) throws -> String {
        let value = try evaluate(expression)
        let text = value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.12g", value)
        return SynapseInfo.json(["expression": expression, "result": text])
    }

    static func evaluate(_ expression: String) throws -> Double {
        let normalized = expression.replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
        var p = Calculator(chars: Array(normalized.filter { !$0.isWhitespace }))
        guard !p.chars.isEmpty else { throw Failure(errorDescription: "The expression is empty.") }
        let v = try p.sum()
        guard p.i == p.chars.count else { throw Failure(errorDescription: "Unexpected '\(p.chars[p.i])' in the expression.") }
        guard v.isFinite else { throw Failure(errorDescription: "The result is not a finite number (division by zero?).") }
        return v
    }

    private init(chars: [Character]) { self.chars = chars }

    private var peek: Character? { i < chars.count ? chars[i] : nil }
    private mutating func eat(_ c: Character) -> Bool { if peek == c { i += 1; return true }; return false }

    private mutating func sum() throws -> Double {
        var v = try product()
        while true {
            if eat("+") { v += try product() } else if eat("-") { v -= try product() } else { return v }
        }
    }

    private mutating func product() throws -> Double {
        var v = try unary()
        while true {
            if eat("*") { v *= try unary() } else if eat("/") { v /= try unary() }
            else if eat("%") { v = v.truncatingRemainder(dividingBy: try unary()) } else { return v }
        }
    }

    private mutating func unary() throws -> Double {
        if eat("-") { return -(try unary()) }
        if eat("+") { return try unary() }
        return try power()
    }

    private mutating func power() throws -> Double {
        let base = try primary()
        return eat("^") ? pow(base, try unary()) : base
    }

    private mutating func primary() throws -> Double {
        if eat("(") {
            let v = try sum()
            guard eat(")") else { throw Failure(errorDescription: "A parenthesis is not closed.") }
            return v
        }
        guard let c = peek else { throw Failure(errorDescription: "The expression ends early.") }
        if c.isNumber || c == "." {
            let start = i
            while let d = peek, d.isNumber || d == "." { i += 1 }
            if let e = peek, e == "e" || e == "E", i + 1 < chars.count, chars[i + 1].isNumber || "+-".contains(chars[i + 1]) {
                i += 2
                while let d = peek, d.isNumber { i += 1 }
            }
            guard let v = Double(String(chars[start..<i])) else { throw Failure(errorDescription: "'\(String(chars[start..<i]))' is not a number.") }
            return v
        }
        guard c.isLetter else { throw Failure(errorDescription: "Unexpected '\(c)' in the expression.") }
        let start = i
        while let d = peek, d.isLetter || d.isNumber { i += 1 }
        let name = String(chars[start..<i]).lowercased()
        switch name {
        case "pi": return .pi
        case "e": return M_E
        default: break
        }
        guard eat("(") else { throw Failure(errorDescription: "Unknown name '\(name)'.") }
        var args = [try sum()]
        while eat(",") { args.append(try sum()) }
        guard eat(")") else { throw Failure(errorDescription: "A parenthesis is not closed.") }
        let one: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "abs": { Swift.abs($0) }, "round": { $0.rounded() }, "floor": { $0.rounded(.down) },
            "ceil": { $0.rounded(.up) }, "ln": { Foundation.log($0) }, "log": { log10($0) }, "log2": { Foundation.log2($0) },
            "exp": { Foundation.exp($0) }, "sin": { Foundation.sin($0) }, "cos": { Foundation.cos($0) }, "tan": { Foundation.tan($0) },
            "asin": { Foundation.asin($0) }, "acos": { Foundation.acos($0) }, "atan": { Foundation.atan($0) },
        ]
        if let f = one[name], args.count == 1 { return f(args[0]) }
        switch (name, args.count) {
        case ("min", 1...): return args.min()!
        case ("max", 1...): return args.max()!
        case ("pow", 2): return Foundation.pow(args[0], args[1])
        default: throw Failure(errorDescription: "Unknown function '\(name)' with \(args.count) argument(s).")
        }
    }
}

// MARK: Web fetch

struct WebPage: Sendable, Equatable {
    var url: String
    var title: String
    var text: String
}

/// Reads a page for the `web_fetch` tool. Addresses on this Mac or the local network are refused, redirects included,
/// so a model can't reach a router or Synapse's own API through it.
enum WebFetch {
    static let maxBytes = 3 * 1024 * 1024
    /// About 1,500 tokens: GGUF models on 16 GB Macs get a 4,096-token context (llama.cpp's --fit), and a page plus search results must fit.
    static let maxCharacters = 6_000

    static func fetch(_ address: String) async throws -> WebPage {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else {
            throw WebSearch.SearchError("web_fetch needs an http(s) address.")
        }
        guard isPublic(url) else { throw WebSearch.SearchError("Addresses on this Mac or the local network can't be read.") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,text/plain;q=0.9,application/json;q=0.8,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req, delegate: PublicRedirects())
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200 else { throw WebSearch.SearchError("The page answered HTTP \(http?.statusCode ?? 0).") }
        let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        guard type.hasPrefix("text/") || type.contains("json") || type.contains("xml") else {
            throw WebSearch.SearchError("The page is \(type), not text.")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        let raw = String(decoding: data, as: UTF8.self)
        let page = type.contains("html") ? readable(raw) : (title: "", text: raw)
        var text = page.text
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) + "\n[… cut at \(maxCharacters) characters]" }
        return WebPage(url: resp.url?.absoluteString ?? url.absoluteString, title: page.title, text: text)
    }

    /// The page's title and its visible text, one block per line.
    static func readable(_ html: String) -> (title: String, text: String) {
        let title = html.firstMatch(of: /(?i)<title[^>]*>(.*?)<\/title>/.dotMatchesNewlines()).map { WebSearch.text(String($0.1)) } ?? ""
        var s = html.replacing(/(?i)<(script|style|noscript|svg|head|nav|footer)[^>]*>.*?<\/\1>/.dotMatchesNewlines(), with: " ")
        s = s.replacing(/<!--.*?-->/.dotMatchesNewlines(), with: " ")
        s = s.replacing(/(?i)<\/?(p|div|br|li|h[1-6]|tr|section|article|header|ul|ol|table|blockquote|pre)\b[^>]*>/, with: "\n")
        let lines = WebSearch.text(s).components(separatedBy: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
        return (title, lines.joined(separator: "\n"))
    }

    /// False for loopback, private, link-local and carrier-grade NAT addresses, `.local` names, and names that don't resolve.
    // shortcut: the name is resolved here and again by URLSession, so a DNS answer that changes in between (rebinding) slips through; pin the address if this tool is ever exposed beyond this Mac.
    static func isPublic(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !host.hasSuffix(".local"), host != "localhost" else { return false }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let n = node {
            guard let addr = n.pointee.ai_addr, isPublic(addr) else { return false }
            node = n.pointee.ai_next
        }
        return true
    }

    private static func isPublic(_ addr: UnsafeMutablePointer<sockaddr>) -> Bool {
        switch Int32(addr.pointee.sa_family) {
        case AF_INET:
            let b = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
            case (172, 16...31), (100, 64...127): return false
            default: return b[0] < 224
            }
        case AF_INET6:
            let b = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            if b.allSatisfy({ $0 == 0 }) || b == Array(repeating: 0, count: 15) + [1] { return false }   // :: and ::1
            if b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] == 0xFF { return false }   // ULA, link-local, multicast
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {   // IPv4-mapped
                var v4 = sockaddr_in(); v4.sin_family = sa_family_t(AF_INET)
                withUnsafeMutableBytes(of: &v4.sin_addr) { $0.copyBytes(from: b[12..<16]) }
                return withUnsafeMutablePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { isPublic($0) } }
            }
            return true
        default:
            return false
        }
    }

    /// Follows a redirect only to a public address.
    private final class PublicRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), WebFetch.isPublic(url) else { return nil }
            return request
        }
    }
}
