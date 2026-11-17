import Foundation
import XCTest
@testable import SynapseCore

/// Real Qwen3.5 in a realtime session answering about an input_image item (the Live camera path).
/// SYNAPSE_E2E=1 with qwen3.5-0.8b downloaded.
final class CameraFrameE2ETests: XCTestCase {
    func testRealtimeSessionSeesTheFrame() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root), models = ModelManager()
        let s = RealtimeSession(model: "qwen3.5-0.8b",
                                services: .real(store: store, models: models, chat: ChatService(store: store, models: models)))
        func send(_ o: [String: Any]) async { await s.handle(try! JSONSerialization.data(withJSONObject: o)) }
        let jpeg = try Data(contentsOf: TestSupport.fixture("zebra.jpg"))
        await send(["type": "session.update", "session": ["type": "realtime", "output_modalities": ["text"]]])
        await send(["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                    "content": [["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]]])
        await send(["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "What animal is this? Answer with one word."]]]])
        await send(["type": "response.create"])
        var text = ""
        for await data in s.events {
            guard let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = e["type"] as? String else { continue }
            if t == "response.output_text.delta" { text += e["delta"] as? String ?? "" }
            if t == "error" { XCTFail("\(e)") }
            if t == "response.done" || t == "error" { break }
        }
        await s.close()
        print("[camera] \(text)")
        XCTAssertTrue(text.lowercased().contains("zebra"), text)
    }
}
