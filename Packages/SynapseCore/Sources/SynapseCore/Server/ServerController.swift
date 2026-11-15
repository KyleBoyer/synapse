import Foundation
import Hummingbird
import NIOCore

public func buildRouter(queue: JobQueue, store: ModelStore, settings: SettingsBox) -> Router<SynapseContext> {
    let router = Router(context: SynapseContext.self)
    router.add(middleware: ErrorBodyMiddleware())
    router.get("health") { _, _ in
        json(["status": "ok", "version": "0.1.0"])
    }
    for group in [router.group(), router.group("k/:key")] {
        group.add(middleware: APIKeyMiddleware(settings: settings))
        addOpenAIRoutes(to: group, queue: queue, store: store, settings: settings)
        addASRRoutes(to: group, queue: queue, store: store, settings: settings)
        addJobRoutes(to: group, queue: queue, settings: settings)
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

    public init(queue: JobQueue, store: ModelStore, settings: SettingsBox) {
        self.queue = queue; self.store = store; self.box = settings
    }

    /// (Re)starts the server from `settings.current` (port / LAN binding). Honors `serverEnabled`.
    public func start() async {
        await stop()
        let s = box.current
        guard s.serverEnabled else { return }
        let host = s.allowLAN ? "0.0.0.0" : "127.0.0.1"
        let port = s.port
        let app = Application(
            router: buildRouter(queue: queue, store: store, settings: box),
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
