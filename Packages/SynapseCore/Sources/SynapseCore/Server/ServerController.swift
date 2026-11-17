import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

public func buildRouter(queue: JobQueue, store: ModelStore, settings: SettingsBox, chat: ChatService? = nil,
                         images: ImageService? = nil, speech: SpeechService? = nil,
                         embeddings: EmbeddingService? = nil, videos: VideoService? = nil,
                         sound: SoundService? = nil) -> Router<SynapseContext> {
    let chat = chat ?? ChatService(store: store)
    let images = images ?? ImageService(store: store, models: ModelManager(), engineFactory: ImageEngines.real)
    let speech = speech ?? SpeechService(store: store, models: ModelManager())
    let embeddings = embeddings ?? EmbeddingService(store: store, models: ModelManager())
    let videos = videos ?? VideoService(store: store, models: ModelManager())
    let sound = sound ?? SoundService(store: store, models: ModelManager())
    let imageFiles = ImageFileCache()
    let router = Router(context: SynapseContext.self)
    router.add(middleware: ErrorBodyMiddleware())
    router.get("health") { _, _ in
        json(["status": "ok", "version": Synapse.version])
    }
    // Every API route answers with and without the /v1 prefix, so a client given only the host works whichever
    // convention it follows (OpenAI SDKs expect base_url to end in /v1; Anthropic's SDK adds /v1 itself).
    // `/k/<key>` carries the API key in the path for clients that cannot send headers (Bazarr). `v1/v1` covers a
    // host/v1 base URL pasted into a client that appends /v1 itself.
    let conversations = LMStudioConversations()
    for prefix in ["v1", "", "v1/v1", "k/:key/v1", "k/:key", "k/:key/v1/v1"] {
        let group = prefix.isEmpty ? router.group() : router.group(RouterPath(prefix))
        group.add(middleware: APIKeyMiddleware(settings: settings))
        addOpenAIRoutes(to: group, queue: queue, store: store, settings: settings)
        addCompletionsRoutes(to: group, chat: chat)
        addASRRoutes(to: group, queue: queue, store: store, settings: settings)
        addJobRoutes(to: group, queue: queue, settings: settings)
        addChatRoutes(to: group, chat: chat, images: images, speech: speech, settings: settings)
        addAnthropicRoutes(to: group, chat: chat)
        addLMStudioRoutes(to: group, chat: chat, conversations: conversations)
        addModelRoutes(to: group, store: store, chat: chat, settings: settings)
        addImageRoutes(to: group, images: images, files: imageFiles, chat: chat, settings: settings)
        addSpeechRoutes(to: group, speech: speech)
        addVoiceRoutes(to: group, speech: speech)
        addEmbeddingRoutes(to: group, embeddings: embeddings)
        addVideoRoutes(to: group, videos: videos)
        addSoundRoutes(to: group, sound: sound)
    }
    return router
}

public actor ServerController {
    public enum Status: Equatable, Sendable {
        case stopped, running(String), failed(String)

        public var label: String {
            switch self {
            case .stopped: return "Server stopped"
            case .running(let a): return "Listening on \(a)"
            case .failed(let m): return "Server error: \(m)"
            }
        }
    }

    public private(set) var status: Status = .stopped
    private let queue: JobQueue
    private let store: ModelStore
    private let box: SettingsBox
    private var task: Task<Void, Never>?

    private let chat: ChatService
    private let images: ImageService
    private let speech: SpeechService
    private let embeddings: EmbeddingService
    private let videos: VideoService
    private let sound: SoundService
    private let realtime: RealtimeServices

    public init(queue: JobQueue, store: ModelStore, settings: SettingsBox, chat: ChatService? = nil, images: ImageService? = nil,
                realtime: RealtimeServices? = nil, speech: SpeechService? = nil, embeddings: EmbeddingService? = nil,
                videos: VideoService? = nil, sound: SoundService? = nil) {
        self.queue = queue; self.store = store; self.box = settings
        let chat = chat ?? ChatService(store: store)
        self.chat = chat
        self.realtime = realtime ?? .real(store: store, models: ModelManager(), chat: chat)
        self.images = images ?? ImageService(store: store, models: ModelManager(), engineFactory: ImageEngines.real)
        self.speech = speech ?? SpeechService(store: store, models: ModelManager())
        self.embeddings = embeddings ?? EmbeddingService(store: store, models: ModelManager())
        self.videos = videos ?? VideoService(store: store, models: ModelManager())
        self.sound = sound ?? SoundService(store: store, models: ModelManager())
    }

    /// (Re)starts the server from `settings.current` (port / LAN binding). Honors `serverEnabled`.
    public func start() async {
        await stop()
        let s = box.current
        guard s.serverEnabled else { return }
        let host = s.allowLAN ? "0.0.0.0" : "127.0.0.1"
        let port = s.port
        let app = Application(
            router: buildRouter(queue: queue, store: store, settings: box, chat: chat, images: images, speech: speech, embeddings: embeddings,
                                 videos: videos, sound: sound),
            server: .http1WebSocketUpgrade(webSocketRouter: buildRealtimeRouter(services: realtime, settings: box),
                                           configuration: realtimeWebSocketConfiguration),
            configuration: .init(address: .hostname(host, port: port)),
            onServerRunning: { [weak self] _ in await self?.set(.running("\(host):\(port)")) })
        task = Task { [weak self] in
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                let msg = "\(error)".lowercased().contains("address already in use") ? "Port \(port) is in use" : error.localizedDescription
                await self?.set(.failed(msg))
            }
        }
    }

    public func stop() async {
        let t = task
        task = nil
        t?.cancel()
        await t?.value
        if case .failed = status { return }
        status = .stopped
    }

    private func set(_ s: Status) { status = s }
}
