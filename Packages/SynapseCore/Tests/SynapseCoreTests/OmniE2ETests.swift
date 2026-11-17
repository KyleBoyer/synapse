import Foundation
import XCTest
@testable import SynapseCore

/// Real Gemma 3n through a managed mlx-vlm server. SYNAPSE_E2E=1 with gemma-3n-e2b downloaded; the first run
/// installs the mlx-vlm runtime (needs network once).
final class OmniE2ETests: XCTestCase {
    private func ask(_ text: String, images: [Data] = [], audios: [URL] = []) async throws -> String {
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let models = ModelManager()
        let chat = ChatService(store: ModelStore(root: root), models: models)
        let spec = try XCTUnwrap(Catalog.spec("gemma-3n-e2b"))
        var answer = "", usage: ChatUsage?
        let start = Date()
        for try await e in try await chat.stream(model: spec, messages: [ChatMessage(role: .user, text: text, images: images, audios: audios)],
                                                 options: ChatOptions(maxTokens: 40, temperature: 0)) {
            if case .delta(let d) = e { answer += d }
            if case .done(_, let u) = e { usage = u }
        }
        print(String(format: "[omni] %@ (prompt %d tokens, %.1f s incl. server start)", answer, usage?.promptTokens ?? -1, Date().timeIntervalSince(start)))
        try await Task.sleep(for: .milliseconds(200))   // the lease is released asynchronously
        await models.unloadAllIdle()   // stops the server process
        return answer
    }

    func testGemma3nHearsAndSees() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try await AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()).decodeToWAV(.media(TestSupport.fixture("en.m4a")), into: dir)
        let heard = try await ask("What does the speaker say? Answer with the exact words.", audios: [wav])
        XCTAssertTrue(heard.lowercased().contains("fox"), heard)
        let seen = try await ask("What animal is this? Answer with one word.", images: [try Data(contentsOf: TestSupport.fixture("zebra.jpg"))])
        XCTAssertTrue(seen.lowercased().contains("zebra"), seen)
    }
}
