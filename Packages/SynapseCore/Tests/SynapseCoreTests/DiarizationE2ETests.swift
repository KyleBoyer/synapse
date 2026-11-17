import Foundation
import XCTest
@testable import SynapseCore

/// Real diarizer and Parakeet. SYNAPSE_E2E=1 with parakeet-v3 and speaker-diarizer downloaded.
final class DiarizationE2ETests: XCTestCase {
    func testTwoVoicesGetTwoSpeakers() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        let q = JobQueue(store: ModelStore(root: root), decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: SettingsBox(s))
        let start = Date()
        let snap = await q.run(JobRequest(input: .media(TestSupport.fixture("two-speakers.m4a")), origin: .api, diarize: true))
        let segments = try XCTUnwrap(snap.transcript?.segments, "\(snap.status)")
        for seg in segments { print("[diarize] \(seg.speaker ?? "-") \(String(format: "%.2f-%.2f", seg.start, seg.end)) \(seg.text)") }
        print(String(format: "[diarize] %.1f s total", Date().timeIntervalSince(start)))
        XCTAssertEqual(snap.status, .done)
        XCTAssertGreaterThanOrEqual(Set(segments.compactMap(\.speaker)).count, 2)
        XCTAssertNotEqual(segments.first?.speaker, segments.last?.speaker)
    }
}
