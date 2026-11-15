import XCTest
@testable import SynapseCore

/// Real model downloads and inference. Run with SYNAPSE_E2E=1 (downloads ~700 MB on first run).
final class E2ETests: XCTestCase {
    private static let storeRoot = FileManager.default.temporaryDirectory.appending(path: "synapse-e2e-models")

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
    }

    private func queue(defaultModel: String) async throws -> JobQueue {
        let store = ModelStore(root: Self.storeRoot)
        for id in ["whisper-tiny", "parakeet-v3"] {
            _ = try await store.download(id) { _ in }
        }
        var s = Settings()
        s.defaultModelID = defaultModel
        return JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: SettingsBox(s))
    }

    private func assertCuesFit(_ t: Transcript, file: StaticString = #filePath, line: UInt = #line) {
        for cue in Subtitles.makeCues(t) {
            XCTAssertLessThanOrEqual(cue.lines.count, 2, file: file, line: line)
            for l in cue.lines { XCTAssertLessThanOrEqual(l.count, 42, file: file, line: line) }
        }
    }

    func testBothEnginesTranscribeMKV() async throws {
        let q = try await queue(defaultModel: "parakeet-v3")
        for model in ["parakeet-v3", "whisper-tiny"] {
            let snap = await q.run(JobRequest(input: .media(TestSupport.fixture("en.mkv")), modelID: model, origin: .gui))
            XCTAssertEqual(snap.status, .done, model)
            let text = snap.transcript?.text.lowercased() ?? ""
            print("[\(model)] \(text)")
            XCTAssertTrue(text.contains("quick brown fox"), "\(model): \(text)")
            assertCuesFit(snap.transcript!)
        }
    }

    func testWhisperAutoDetectsFrench() async throws {
        let q = try await queue(defaultModel: "whisper-tiny")
        let snap = await q.run(JobRequest(input: .media(TestSupport.fixture("fr.m4a")), modelID: "whisper-tiny", origin: .gui))
        XCTAssertEqual(snap.status, .done)
        print("[fr] \(snap.transcript?.text ?? "")")
        XCTAssertEqual(snap.transcript?.language, "fr")
    }

    func testRawPCMInput() async throws {
        let q = try await queue(defaultModel: "parakeet-v3")
        let snap = await q.run(JobRequest(input: .pcm16le(TestSupport.fixture("en.pcm")), origin: .api))
        XCTAssertEqual(snap.status, .done)
        XCTAssertTrue(snap.transcript?.text.lowercased().contains("quick brown fox") == true)
    }

    func testDetectLanguage() async throws {
        let q = try await queue(defaultModel: "parakeet-v3")
        let r = try await q.detectLanguage(.media(TestSupport.fixture("fr.m4a")))
        XCTAssertEqual(r?.code, "fr")
    }
}
