import Foundation
import Hummingbird
import HummingbirdTesting
import Synchronization
import XCTest
@testable import SynapseCore

/// `/v1/synapse/models`, the routes behind the `synapse` command-line tool, with fake app handlers.
final class MyModelsAPITests: XCTestCase {
    private let lora = CustomModel(repo: "AtomicChat/Inkling-2-Mini-Uncensored-GGUF", engine: .gguf, displayName: "Uncensored LoRA",
                                   approxMB: 44, ramGB: nil, files: ["Inkling-2-Mini-Uncensored-LoRA.gguf"], baseModel: "inkling-2-mini")

    private func app(_ models: MyModels) throws -> some ApplicationProtocol {
        let store = try TestSupport.store(downloaded: ["parakeet-v3"])
        let box = SettingsBox(Settings())
        return Application(router: buildRouter(queue: JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: box),
                                               store: store, settings: box, myModels: models))
    }

    func testListAndDeleteFromThisMac() async throws {
        let removed = Mutex<[String]>([])
        let models = MyModels()
        let entry = MyModels.Entry(lora, state: .downloading(0.5))
        models.install(.init(list: { [entry] }, add: { _, _ in }, remove: { id in removed.withLock { $0.append(id) } }))
        try await app(models).test(.live) { c in
            try await c.execute(uri: "/v1/synapse/models", method: .get) { r in
                XCTAssertEqual(r.status, .ok)
                let body = try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]
                let first = (body?["data"] as? [[String: Any]])?.first
                XCTAssertEqual(first?["id"] as? String, "AtomicChat/Inkling-2-Mini-Uncensored-GGUF/Inkling-2-Mini-Uncensored-LoRA")
                XCTAssertEqual(first?["state"] as? String, "downloading 50%")
                XCTAssertEqual(first?["base"] as? String, "inkling-2-mini")
            }
            try await c.execute(uri: "/v1/synapse/models/not/listed", method: .delete) { XCTAssertEqual($0.status, .notFound) }
            try await c.execute(uri: "/v1/synapse/models/\(entry.id)", method: .delete) { XCTAssertEqual($0.status, .ok) }
        }
        XCTAssertEqual(removed.withLock { $0 }, [entry.id])
    }

    func testOtherMachinesAndAnUnreadyAppAreRefused() async throws {
        let models = MyModels()
        try await app(models).test(.live) { c in
            try await c.execute(uri: "/v1/synapse/models", method: .get) { XCTAssertEqual($0.status, .serviceUnavailable) }
        }
        models.install(.init(list: { [] }, add: { _, _ in }, remove: { _ in }))
        // In-process requests carry no client address, like a request from a machine that is not this Mac.
        try await app(models).test(.router) { c in
            try await c.execute(uri: "/v1/synapse/models/x/y", method: .delete) { XCTAssertEqual($0.status, .forbidden) }
        }
    }
}
