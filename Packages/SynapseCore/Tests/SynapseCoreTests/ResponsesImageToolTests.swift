import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

/// The image tool without a chat model: the user's text becomes the prompt (the Qwen path runs in the SDK check).
final class ResponsesImageToolTests: XCTestCase, @unchecked Sendable {
    private func app(downloaded: [String] = ["flux2-klein-4b"]) throws -> Application<RouterResponder<SynapseContext>> {
        let store = try TestSupport.store(downloaded: downloaded)
        let models = ModelManager(config: .init(budgetBytes: 1 << 40, idleUnloadAfter: nil))
        let images = ImageService(store: store, models: models, engineFactory: { _, _ in FakeImageEngine() })
        let box = SettingsBox(Settings())
        let queue = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")), settings: box)
        return Application(router: buildRouter(queue: queue, store: store, settings: box, images: images))
    }

    private func body(_ extra: [String: Any]) throws -> ByteBuffer {
        var b: [String: Any] = ["input": "Create a photograph of a red teapot.",
                                "tools": [["type": "image_generation", "size": "256x256"]],
                                "tool_choice": ["type": "image_generation"]]
        b.merge(extra) { $1 }
        return ByteBuffer(data: try JSONSerialization.data(withJSONObject: b))
    }

    func testNonStreamingProducesCompletedImageCall() async throws {
        try await app().test(.router) { client in
            let r = try await client.execute(uri: "/v1/responses", method: .post, headers: [.contentType: "application/json"], body: try self.body([:]))
            XCTAssertEqual(r.status, .ok, String(buffer: r.body))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any])
            XCTAssertEqual(json["status"] as? String, "completed")
            XCTAssertEqual(json["model"] as? String, "flux2-klein-4b")
            let output = try XCTUnwrap(json["output"] as? [[String: Any]])
            XCTAssertEqual(output.count, 1)
            XCTAssertEqual(output[0]["type"] as? String, "image_generation_call")
            XCTAssertEqual(output[0]["status"] as? String, "completed")
            XCTAssertEqual(output[0]["size"] as? String, "256x256")
            XCTAssertTrue((output[0]["revised_prompt"] as? String)?.contains("teapot") == true)
            let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(output[0]["result"] as? String)))
            XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
            let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.first?["type"] as? String, "image_generation")
        }
    }

    func testStreamingEventOrderAndPartials() async throws {
        try await app().test(.router) { client in
            let r = try await client.execute(uri: "/v1/responses", method: .post, headers: [.contentType: "application/json"],
                                             body: try self.body(["stream": true, "tools": [["type": "image_generation", "size": "256x256", "partial_images": 2]]]))
            XCTAssertEqual(r.status, .ok)
            let events = String(buffer: r.body).split(separator: "\n").filter { $0.hasPrefix("data: ") }
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any] }
            let types = events.compactMap { $0["type"] as? String }
            XCTAssertEqual(types.first, "response.created")
            XCTAssertEqual(types.last, "response.completed")
            XCTAssertEqual(types.filter { $0 == "response.image_generation_call.partial_image" }.count, 2)
            for name in ["response.output_item.added", "response.image_generation_call.in_progress",
                         "response.image_generation_call.generating", "response.image_generation_call.completed", "response.output_item.done"] {
                XCTAssertTrue(types.contains(name), name)
            }
            XCTAssertEqual(events.compactMap { $0["sequence_number"] as? Int }, Array(0..<events.count))
        }
    }

    /// Function tools alone go to the chat model (ChatAPITests); mixed with image_generation, the image tool refuses them.
    func testRejectsFunctionToolsBesideImageGenerationAndMissingImageModel() async throws {
        try await app().test(.router) { client in
            let r = try await client.execute(uri: "/v1/responses", method: .post, headers: [.contentType: "application/json"],
                                             body: try self.body(["tools": [["type": "image_generation"], ["type": "function", "name": "x"]]]))
            XCTAssertEqual(r.status, .badRequest)
        }
        try await app(downloaded: []).test(.router) { client in
            let r = try await client.execute(uri: "/v1/responses", method: .post, headers: [.contentType: "application/json"], body: try self.body([:]))
            XCTAssertEqual(r.status, .serviceUnavailable)
        }
    }

    func testEditNeedsAnImageAndAnEditModel() async throws {
        try await app(downloaded: ["z-image-turbo"]).test(.router) { client in
            let r = try await client.execute(uri: "/v1/responses", method: .post, headers: [.contentType: "application/json"],
                                             body: try self.body(["tools": [["type": "image_generation", "action": "edit"]]]))
            XCTAssertEqual(r.status, .badRequest)
        }
    }
}
