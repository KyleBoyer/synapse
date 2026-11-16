import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// Proxies chat through a real vOOM checkout. SYNAPSE_VOOM_CHECKOUT=~/git/vOOM (optionally SYNAPSE_VOOM_MODEL).
final class VOOME2ETests: XCTestCase, @unchecked Sendable {
    func testChatThroughVOOM() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let checkout = env["SYNAPSE_VOOM_CHECKOUT"] else { throw XCTSkip("set SYNAPSE_VOOM_CHECKOUT") }
        let model = "voom:" + (env["SYNAPSE_VOOM_MODEL"] ?? "SmolLM2-135M")
        var s = Settings()
        s.voomCheckout = checkout
        let box = SettingsBox(s)
        let store = try TestSupport.store(downloaded: [])
        let models = ModelManager(config: .init(budgetBytes: 1 << 40, idleUnloadAfter: nil))
        let chat = ChatService(store: store, models: models)
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box)
        let app = Application(router: buildRouter(queue: queue, store: store, settings: box, chat: chat))
        try await app.test(.router) { client in
            let list = try await client.execute(uri: "/v1/models", method: .get)
            XCTAssertTrue(String(buffer: list.body).contains(model), "models list lacks \(model)")

            let body = try JSONSerialization.data(withJSONObject: [
                "model": model, "max_tokens": 16, "temperature": 0,
                "messages": [["role": "user", "content": "The capital of France is"]]])
            let start = Date()
            let r = try await client.execute(uri: "/v1/chat/completions", method: .post,
                                             headers: [.contentType: "application/json"], body: ByteBuffer(data: body))
            XCTAssertEqual(r.status, .ok, String(buffer: r.body))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any])
            let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            print("[voom] \(model) replied in \(Int(Date().timeIntervalSince(start)))s: \(content ?? "nil")")
            XCTAssertFalse((content ?? "").isEmpty)

            var streamed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            streamed["stream"] = true
            let sr = try await client.execute(uri: "/v1/chat/completions", method: .post, headers: [.contentType: "application/json"],
                                              body: ByteBuffer(data: try JSONSerialization.data(withJSONObject: streamed)))
            XCTAssertEqual(sr.status, .ok)
            let text = String(buffer: sr.body)
            XCTAssertTrue(text.contains("data: "), text)
            XCTAssertTrue(text.contains("[DONE]"), text)
        }
        let resident = await models.isLoaded(VOOMRuntime.residentID)
        XCTAssertTrue(resident, "vOOM should be registered with the ModelManager")
        let unloaded = await models.unload(VOOMRuntime.residentID)
        XCTAssertTrue(unloaded, "vOOM should stop when its lease is released")
    }
}
