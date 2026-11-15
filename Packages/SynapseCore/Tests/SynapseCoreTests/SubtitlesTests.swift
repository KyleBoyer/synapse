import XCTest
@testable import SynapseCore

final class SubtitlesTests: XCTestCase {
    private func srt1(_ s: Double) -> String {
        Subtitles.srt([Cue(start: s, end: s, lines: ["x"])]).components(separatedBy: "\n")[1].components(separatedBy: " --> ")[0]
    }
    private func words(_ text: String, start: Double = 0, step: Double = 0.3) -> [Word] {
        text.split(separator: " ").enumerated().map { Word(start: start + Double($0.offset) * step, end: start + Double($0.offset) * step + step, text: " " + $0.element) }
    }
    private func transcript(_ w: [Word]) -> Transcript {
        Transcript(language: "en", duration: w.last?.end ?? 0, segments: [Segment(start: w.first?.start ?? 0, end: w.last?.end ?? 0, text: w.map(\.text).joined(), words: w)])
    }

    func testSrtTimestamps() {
        XCTAssertEqual(srt1(0), "00:00:00,000")
        XCTAssertEqual(srt1(1.2345), "00:00:01,235")
        XCTAssertEqual(srt1(3725.5), "01:02:05,500")
        XCTAssertEqual(srt1(360000), "100:00:00,000")
    }

    func testLongSegmentSplitsWithinLimits() {
        let t = transcript(words(Array(repeating: "lorem ipsum dolor", count: 20).joined(separator: " ")))
        let cues = Subtitles.makeCues(t)
        XCTAssertGreaterThan(cues.count, 1)
        for c in cues {
            XCTAssertLessThanOrEqual(c.lines.count, 2)
            for l in c.lines { XCTAssertLessThanOrEqual(l.count, 42) }
        }
    }

    func testGapSplits() {
        let w = [Word(start: 0, end: 0.5, text: " hello"), Word(start: 2, end: 2.5, text: " world")]
        XCTAssertEqual(Subtitles.makeCues(transcript(w)).count, 2)
    }

    func testSentenceEndSplits() {
        let w = words("This is a complete sentence. And another one")
        let cues = Subtitles.makeCues(transcript(w))
        XCTAssertEqual(cues.map { $0.lines.joined(separator: " ") }, ["This is a complete sentence.", "And another one"])
    }

    func testNoOverlapAfterMinDuration() {
        let segs = (0..<5).map { Segment(start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.1, text: "w\($0)") }
        let cues = Subtitles.makeCues(Transcript(language: nil, duration: 1, segments: segs))
        XCTAssertEqual(cues.count > 0, true)
        for (a, b) in zip(cues, cues.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
    }

    func testWordlessLongSegmentKeepsText() {
        let text = String(repeating: "abcdefghi ", count: 20).trimmingCharacters(in: .whitespaces) // 199 chars
        let cues = Subtitles.makeCues(Transcript(language: nil, duration: 5, segments: [Segment(start: 0, end: 5, text: text)]))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].lines.joined(separator: " "), text)
    }

    func testVTTAndEmpty() {
        let t = transcript(words("hello world"))
        XCTAssertTrue(Subtitles.render(t, as: .vtt, task: .transcribe).body.hasPrefix("WEBVTT"))
        XCTAssertTrue(Subtitles.render(t, as: .vtt, task: .transcribe).body.contains("00:00:00.000 --> "))
        let empty = Transcript(language: nil, duration: 0, segments: [])
        XCTAssertEqual(Subtitles.render(empty, as: .srt, task: .transcribe).body, "")
    }

    func testTSV() {
        let t = Transcript(language: "en", duration: 2, segments: [Segment(start: 0, end: 1.2345, text: " hi ")])
        XCTAssertEqual(Subtitles.tsv(t), "start\tend\ttext\n0\t1235\thi\n")
    }

    func testJSONParseBack() throws {
        let t = transcript(words("hello \"quoted\" world"))
        let a = try JSONSerialization.jsonObject(with: Data(Subtitles.openAIJSON(t).utf8)) as! [String: Any]
        XCTAssertEqual(a["text"] as? String, t.text)
        let v = try JSONSerialization.jsonObject(with: Data(Subtitles.verboseJSON(t, task: .translate).utf8)) as! [String: Any]
        XCTAssertEqual(v["task"] as? String, "translate")
        XCTAssertEqual(v["language"] as? String, "en")
        XCTAssertEqual((v["segments"] as! [[String: Any]]).first?["id"] as? Int, 0)
        XCTAssertEqual((v["words"] as! [[String: Any]]).count, 3)
        XCTAssertEqual(Subtitles.render(t, as: .json, task: .transcribe).contentType, "application/json")
        XCTAssertEqual(Subtitles.render(t, as: .srt, task: .transcribe).contentType, "application/x-subrip")
    }
}
