import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// WebSocket router for `/v1/realtime` (and `/k/<key>/v1/realtime`). Pair it with the HTTP router via
/// `Application(router:, server: .http1WebSocketUpgrade(webSocketRouter:, configuration: realtimeWebSocketConfiguration))`.
public func buildRealtimeRouter(services: RealtimeServices, settings: SettingsBox) -> Router<BasicWebSocketRequestContext> {
    let router = Router(context: BasicWebSocketRequestContext.self)
    for path in ["v1/realtime", "realtime", "k/:key/v1/realtime", "k/:key/realtime"] {
        router.ws(RouterPath(path), shouldUpgrade: { request, context in
            let s = settings.current
            if s.allowLAN {
                var supplied = context.parameters.get("key")
                if supplied == nil, let h = request.headers[.authorization], h.hasPrefix("Bearer ") { supplied = String(h.dropFirst(7)) }
                guard let supplied, APIKeyMiddleware.constantTimeEqual(supplied, s.apiKey) else {
                    throw HTTPError(.unauthorized, message: "Invalid or missing API key.")
                }
            }
            return .upgrade([:])
        }, onUpgrade: { inbound, outbound, context in
            let q = context.request.uri.queryParameters
            let session = RealtimeSession(model: q["model"].map(String.init), transcriptionOnly: q["intent"] == "transcription", services: services)
            try await withThrowingTaskGroup(of: Void.self) { group in
                // One task owns every outbound write.
                group.addTask {
                    for await event in session.events { try await outbound.write(.text(String(decoding: event, as: UTF8.self))) }
                }
                group.addTask {
                    defer { Task { await session.close() } }
                    for try await message in inbound.messages(maxSize: 1 << 24) {
                        if case .text(let text) = message { await session.handle(Data(text.utf8)) }
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
                await session.close()
                try await group.waitForAll()
            }
        })
    }
    return router
}

public let realtimeWebSocketConfiguration = WebSocketServerConfiguration(maxFrameSize: 1 << 22)
