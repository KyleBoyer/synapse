import Foundation
import XCTest
@testable import SynapseCore

/// Real Qwen3.5 on a video. SYNAPSE_E2E=1 with qwen3.5-0.8b downloaded.
final class VideoInputE2ETests: XCTestCase {
    func testQwenNamesTheAnimalInAVideo() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let chat = ChatService(store: ModelStore(root: root))
        let spec = try XCTUnwrap(Catalog.spec("qwen3.5-0.8b"))
        let supported = await chat.supportsVideo(spec)
        XCTAssertTrue(supported)
        let start = Date()
        var answer = "", usage: ChatUsage?
        for try await e in try await chat.stream(
            model: spec,
            messages: [ChatMessage(role: .user, text: "What animal is in this video? Answer with one word.",
                                   videos: [TestSupport.fixture("zebra.mp4")])],
            options: ChatOptions(maxTokens: 16, temperature: 0)) {
            switch e {
            case .delta(let t): answer += t
            case .done(_, let u): usage = u
            default: break
            }
        }
        print(String(format: "[video] %@ (prompt %d tokens, %.1f s incl. load)", answer, usage?.promptTokens ?? -1,
                     Date().timeIntervalSince(start)))
        XCTAssertTrue(answer.lowercased().contains("zebra"), answer)
    }
}
