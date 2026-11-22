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
    /// Anthropic's max_uses; nil is no limit beyond the loop's rounds.
    var maxSearches: Int?
    var image: ImageToolConfig?
    var synapse = false
    /// The app's tool settings: search provider, image model and size defaults, rounds.
    var settings = ToolSettings()

    var isEmpty: Bool { !webSearch && image == nil && !synapse }

    static func isServerType(_ type: String) -> Bool {
        type == "web_search" || type.hasPrefix("web_search_") || type == "image_generation" || type == "synapse"
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
                server.maxSearches = t["max_uses"]?.number.map(Int.init)
            } else if type == "image_generation" {
                server.image = try ImageToolConfig(t)
            } else if type == "synapse" {
                server.synapse = true
            } else {
                rest.append(t)
            }
        }
        if settings.alwaysOn.contains(.webSearch), settings.searchProvider != .off { server.webSearch = true }
        if settings.alwaysOn.contains(.imageGeneration), server.image == nil { server.image = try ImageToolConfig(.object([:])) }
        if settings.alwaysOn.contains(.synapse) { server.synapse = true }
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
        if image != nil { out.append(ServerToolKind.image.function) }
        if synapse { out += [ServerToolKind.time.function, ServerToolKind.models.function, ServerToolKind.status.function] }
        return out
    }

    func kind(of name: String) -> ServerToolKind? {
        guard let kind = ServerToolKind(rawValue: name) else { return nil }
        switch kind {
        case .webSearch: return webSearch ? kind : nil
        case .image: return image != nil ? kind : nil
        case .time, .models, .status: return synapse ? kind : nil
        }
    }
}

/// A built-in tool, by the function name the model calls.
enum ServerToolKind: String, Sendable {
    case webSearch = "web_search", image = "generate_image"
    case time = "synapse_time", models = "synapse_models", status = "synapse_status"

    var function: ChatTool {
        let none = #"{"type":"object","properties":{}}"#
        switch self {
        case .webSearch:
            return ChatTool(name: rawValue, description: "Search the web. Use it for current events, facts you are unsure of, and anything after your training. Returns titles, links and snippets.",
                            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"What to search for"}},"required":["query"]}"#)
        case .image:
            return ChatTool(name: rawValue, description: "Create or edit an image. Call this whenever the user asks for a picture, drawing, photo or image edit. The image is shown to the user.",
                            parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed description of the image to create: subject, setting, style, lighting"}},"required":["prompt"]}"#)
        case .time:
            return ChatTool(name: rawValue, description: "The current date, time and time zone.", parametersJSON: none)
        case .models:
            return ChatTool(name: rawValue, description: "The AI models installed in Synapse, the app running you: what each one does, its size, and which are loaded.", parametersJSON: none)
        case .status:
            return ChatTool(name: rawValue, description: "Synapse's version, this Mac's memory, and the models loaded in memory now with how much each uses and when it loaded.", parametersJSON: none)
        }
    }

    /// Output item id prefix, as OpenAI's (ws_, ig_); st_ for Synapse's own.
    var idPrefix: String {
        switch self {
        case .webSearch: "ws_"
        case .image: "ig_"
        case .time, .models, .status: "st_"
        }
    }
}

struct WebResult: Sendable, Equatable, Encodable {
    var title: String
    var url: String
    var snippet: String
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
        case .image?: return "The image was created and is shown to the user. Do not repeat it as a link."
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
    let runner = ServerToolRunner(tools: tools, maxRounds: min(max(tools.settings.maxRounds, 2), 10))
    let chat = services.chat
    let first = wrap(try await chat.stream(model: spec, messages: messages, options: runner.options(options, round: 1)))
    return runner.stream(messages: messages, options: options, first: first,
                         generate: { wrap(try await chat.stream(model: spec, messages: $0, options: $1)) },
                         execute: { await services.execute($0, $1) })
}

func newServerToolID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

/// The services built-in tools use.
struct ServerToolServices: Sendable {
    var chat: ChatService
    var images: ImageService
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
            case .time:
                call.output = .info(SynapseInfo.time())
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

    private func drawImage(_ prompt: String, _ conversation: [ChatMessage]) async throws -> GeneratedImage {
        guard let config = tools.image else { throw ChatParse.bad("image_generation is not on.") }
        let prompt = prompt.isEmpty ? conversation.last(where: { $0.role == .user })?.text ?? "" : prompt
        let sources = conversation.last(where: { $0.role == .user && !$0.images.isEmpty })?.images ?? []
        let edit = config.action == "edit" || (config.action == "auto" && !sources.isEmpty)
        let spec = try await images.resolve(config.model, edit: edit)
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
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func time(now: Date = Date(), zone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = zone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return json(["now": iso.string(from: now), "readable": f.string(from: now), "time_zone": zone.identifier,
                     "utc_offset_hours": Double(zone.secondsFromGMT(for: now)) / 3600, "unix": Int(now.timeIntervalSince1970)])
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
