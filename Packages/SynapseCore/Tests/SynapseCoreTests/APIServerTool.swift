import Foundation
import Hummingbird
import HummingbirdWebSocket
import XCTest
@testable import SynapseCore

/// Opt-in server for the official SDK checks, using the same router and services as the app.
final class APIServerTool: XCTestCase {
    func testServe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SYNAPSE_API_TEST_SERVER"] == "1" else { throw XCTSkip("set SYNAPSE_API_TEST_SERVER=1") }
        let root = env["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        let models = ModelManager()
        var initial = Settings()
        initial.voomCheckout = env["SYNAPSE_VOOM_CHECKOUT"]
        // SYNAPSE_API_TEST_KEY turns on key auth (as LAN mode does) while still binding loopback.
        if let key = env["SYNAPSE_API_TEST_KEY"] { initial.allowLAN = true; initial.apiKey = key }
        let settings = SettingsBox(initial)
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: settings, models: models)
        let chat = ChatService(store: store, models: models)
        let factory: ImageService.EngineFactory = env["SYNAPSE_FAKE_IMAGES"] == "1" ? { @Sendable _, _ in FakeImageEngine() } : ImageEngines.real
        let images = ImageService(store: store, models: models, engineFactory: factory)
        let port = env["SYNAPSE_API_TEST_PORT"].flatMap(Int.init) ?? 19000
        print("SDK check server on 127.0.0.1:\(port), fake images: \(env["SYNAPSE_FAKE_IMAGES"] == "1")")
        let realtime = RealtimeServices.real(store: store, models: models, chat: chat, tts: env["SYNAPSE_TTS"] ?? "pocket-tts")
        let app = Application(router: buildRouter(queue: queue, store: store, settings: settings, chat: chat, images: images,
                                                speech: SpeechService(store: store, models: models, encoder: AudioEncoder(ffmpegURL: try TestSupport.ffmpeg()))),
                              server: .http1WebSocketUpgrade(webSocketRouter: buildRealtimeRouter(services: realtime, settings: settings),
                                                             configuration: realtimeWebSocketConfiguration),
                              configuration: .init(address: .hostname("127.0.0.1", port: port)))
        try await app.runService()
    }
}
