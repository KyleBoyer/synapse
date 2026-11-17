import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import XCTest
@testable import SynapseCore

private func w(_ start: Double, _ end: Double, _ text: String) -> Word { Word(start: start, end: end, text: text) }

/// A transcript with two speakers' words in one segment, and fixed turns: A for 0-2 s, B for 2-4 s.
private actor TwoVoiceEngine: TranscriptionEngine {
    func transcribe(wav: URL, language: String?, task: TaskKind, progress: @escaping @Sendable (Double?) -> Void) async throws -> Transcript {
        Transcript(language: "en", duration: 4, segments: [
            Segment(start: 0.2, end: 3.8, text: " Hello there. I am fine.",
                    words: [w(0.2, 0.8, " Hello"), w(0.9, 1.5, " there."), w(2.2, 2.6, " I"), w(2.7, 3.0, " am"), w(3.1, 3.8, " fine.")]),
        ])
    }
    func detectLanguage(wav: URL) async throws -> (code: String, confidence: Double) { ("en", 1) }
}

private actor FixedDiarizer: SpeakerDiarizing {
    func diarize(wav: URL) async throws -> [SpeakerTurn] {
        [SpeakerTurn(speaker: "A", start: 0, end: 2), SpeakerTurn(speaker: "B", start: 2, end: 4)]
    }
}

private let turns = [SpeakerTurn(speaker: "A", start: 0, end: 2), SpeakerTurn(speaker: "B", start: 2, end: 4)]

final class SpeakerAssignerTests: XCTestCase {
    func testSplitsSegmentWhereSpeakerChanges() {
        let t = Transcript(language: "en", duration: 4, segments: [
            Segment(start: 1, end: 3, text: " one two three", words: [w(1.0, 1.4, " one"), w(1.5, 1.9, " two"), w(2.3, 2.9, " three")]),
        ])
        let out = SpeakerAssigner.assign(t, turns: turns)
        XCTAssertEqual(out.segments.map(\.speaker), ["A", "B"])
        XCTAssertEqual(out.segments.map(\.text), ["one two", "three"])
        XCTAssertEqual(out.segments.map(\.start), [1.0, 2.3])
        XCTAssertEqual(out.segments.map(\.end), [1.9, 2.9])
    }

    func testWordlessSegmentTakesMajorityAndNoTurnsChangesNothing() {
        let t = Transcript(language: "en", duration: 4, segments: [Segment(start: 1.5, end: 3.9, text: "mostly B")])
        XCTAssertEqual(SpeakerAssigner.assign(t, turns: turns).segments.first?.speaker, "B")
        XCTAssertEqual(SpeakerAssigner.assign(t, turns: []), t)
        // Outside every turn: the nearest one wins.
        let late = Transcript(language: "en", duration: 9, segments: [Segment(start: 8, end: 9, text: "late")])
        XCTAssertEqual(SpeakerAssigner.assign(late, turns: turns).segments.first?.speaker, "B")
    }

    func testRelabelsByFirstAppearance() {
        let raw = [SpeakerTurn(speaker: "spk7", start: 0, end: 1), SpeakerTurn(speaker: "spk2", start: 1, end: 2),
                   SpeakerTurn(speaker: "spk7", start: 2, end: 3)]
        XCTAssertEqual(SpeakerAssigner.relabel(raw).map(\.speaker), ["A", "B", "A"])
    }
}

final class DiarizedSubtitlesTests: XCTestCase {
    private let t = SpeakerAssigner.assign(Transcript(language: "en", duration: 4, segments: [
        Segment(start: 0.2, end: 3.8, text: " Hello there. I am fine.",
                words: [w(0.2, 0.8, " Hello"), w(0.9, 1.5, " there."), w(2.2, 2.6, " I"), w(2.7, 3.0, " am"), w(3.1, 3.8, " fine.")]),
    ]), turns: turns)

    func testSRTPrefixesAndVTTUsesVoiceTags() {
        let srt = Subtitles.render(t, as: .srt).body
        XCTAssertTrue(srt.contains("A: Hello there."), srt)
        XCTAssertTrue(srt.contains("B: I am fine."), srt)
        let vtt = Subtitles.render(t, as: .vtt).body
        XCTAssertTrue(vtt.contains("<v Speaker A>Hello there."), vtt)
        XCTAssertTrue(vtt.contains("<v Speaker B>I am fine."), vtt)
    }

    func testPrefixedLinesStayWithinLimit() {
        let words = (0..<30).map { w(Double($0) * 0.2, Double($0) * 0.2 + 0.15, " word\($0)") }
        let long = SpeakerAssigner.assign(Transcript(language: "en", duration: 7, segments: [
            Segment(start: 0, end: 6, text: words.map(\.text).joined(), words: words)]), turns: [SpeakerTurn(speaker: "A", start: 0, end: 7)])
        for line in Subtitles.render(long, as: .srt).body.split(separator: "\n") where !line.contains("-->") && Int(line) == nil {
            XCTAssertLessThanOrEqual(line.count, 42, String(line))
        }
    }

    func testDiarizedJSONShape() throws {
        let body = Subtitles.render(t, as: .diarizedJSON).body
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let segs = try XCTUnwrap(o["segments"] as? [[String: Any]])
        XCTAssertEqual(segs.map { $0["speaker"] as? String }, ["A", "B"])
        XCTAssertEqual(segs.first?["type"] as? String, "transcript.text.segment")
        XCTAssertEqual(segs.first?["id"] as? String, "seg_0")
        XCTAssertEqual((o["usage"] as? [String: Any])?["type"] as? String, "duration")
        XCTAssertTrue(Subtitles.render(t, as: .verboseJSON).body.contains("\"speaker\""))
    }
}

final class DiarizationJobTests: XCTestCase {
    private func queue(downloaded: [String]) throws -> JobQueue {
        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        return JobQueue(store: try TestSupport.store(downloaded: downloaded),
                        decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: SettingsBox(s),
                        engineFactory: { _, _ in TwoVoiceEngine() }, diarizerFactory: { _ in FixedDiarizer() })
    }

    func testDiarizedJobLabelsSpeakers() async throws {
        let q = try queue(downloaded: ["parakeet-v3", "speaker-diarizer"])
        let snap = await q.run(JobRequest(input: .media(TestSupport.fixture("en.m4a")), origin: .api, diarize: true))
        XCTAssertEqual(snap.status, .done)
        XCTAssertEqual(snap.transcript?.segments.map(\.speaker), ["A", "B"])
    }

    func testMissingDiarizerFailsWithDownloadHint() async throws {
        let q = try queue(downloaded: ["parakeet-v3"])
        let snap = await q.run(JobRequest(input: .media(TestSupport.fixture("en.m4a")), origin: .api, diarize: true))
        guard case .failed(let message) = snap.status else { return XCTFail("expected failure, got \(snap.status)") }
        XCTAssertTrue(message.contains("Speaker diarization"), message)
    }

    func testRouteReturnsDiarizedJSONForTheDiarizeModelAlias() async throws {
        let store = try TestSupport.store(downloaded: ["parakeet-v3", "speaker-diarizer"])
        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        let box = SettingsBox(s)
        let q = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: box,
                         engineFactory: { _, _ in TwoVoiceEngine() }, diarizerFactory: { _ in FixedDiarizer() })
        let audio = try Data(contentsOf: TestSupport.fixture("en.m4a"))
        var body = ByteBuffer()
        let boundary = "XyZ"
        for (name, value) in [("model", "gpt-4o-transcribe-diarize"), ("response_format", "diarized_json")] {
            body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.writeBytes(audio)
        body.writeString("\r\n--\(boundary)--\r\n")
        let payload = body
        try await Application(router: buildRouter(queue: q, store: store, settings: box)).test(.router) { c in
            try await c.execute(uri: "/v1/audio/transcriptions", method: .post,
                                headers: [.contentType: "multipart/form-data; boundary=\(boundary)"], body: payload) { r in
                XCTAssertEqual(r.status, .ok)
                let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any])
                XCTAssertEqual((o["segments"] as? [[String: Any]])?.compactMap { $0["speaker"] as? String }, ["A", "B"])
            }
        }
    }
}

final class WatchFolderCompatTests: XCTestCase {
    /// Settings saved before diarization existed must still decode, or every watched folder would be lost.
    func testOldWatchFolderDecodes() throws {
        let old = #"{"path":"/Volumes/Media/TV","modelID":"parakeet-v3","task":"transcribe"}"#
        let f = try JSONDecoder().decode(WatchFolder.self, from: Data(old.utf8))
        XCTAssertEqual(f.path, "/Volumes/Media/TV")
        XCTAssertFalse(f.diarize)
        let roundTrip = try JSONDecoder().decode(WatchFolder.self, from: JSONEncoder().encode(WatchFolder(path: "/x", diarize: true)))
        XCTAssertTrue(roundTrip.diarize)
    }
}
