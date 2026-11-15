import XCTest
@testable import SynapseCore

actor CountingEngine: TranscriptionEngine {
    static let transcript = Transcript(language: "en", duration: 2, segments: [
        Segment(start: 0, end: 2, text: " The quick brown fox.",
                words: [Word(start: 0, end: 0.5, text: " The"), Word(start: 0.5, end: 1, text: " quick"),
                        Word(start: 1, end: 1.5, text: " brown"), Word(start: 1.5, end: 2, text: " fox.")])
    ])
    private var active = 0
    private(set) var maxActive = 0
    private(set) var calls = 0
    let delay: Duration
    init(delay: Duration = .milliseconds(100)) { self.delay = delay }

    func transcribe(wav: URL, language: String?, task: TaskKind,
                    progress: @escaping @Sendable (Double?) -> Void) async throws -> Transcript {
        active += 1; calls += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return Self.transcript
    }

    func detectLanguage(wav: URL) async throws -> (code: String, confidence: Double) { ("fr", 0.9) }
}

/// Shared helpers for tests that need a queue with a fake engine and a "downloaded" model.
enum TestSupport {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func ffmpeg() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["SYNAPSE_FFMPEG"] { return URL(fileURLWithPath: env) }
        let url = repoRoot.appending(path: "vendor/ffmpeg/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("run scripts/build-ffmpeg.sh") }
        return url
    }

    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: name)
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "synapse-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A ModelStore whose manifest marks `ids` as downloaded.
    static func store(downloaded ids: [String]) throws -> ModelStore {
        let root = try tempDir()
        var manifest: [String: String] = [:]
        for id in ids {
            try FileManager.default.createDirectory(at: root.appending(path: id), withIntermediateDirectories: true)
            manifest[id] = id
        }
        try JSONEncoder().encode(manifest).write(to: root.appending(path: "manifest.json"))
        return ModelStore(root: root)
    }
}

final class JobQueueTests: XCTestCase {
    private func makeQueue(engine: CountingEngine, downloaded: [String] = ["parakeet-v3", "whisper-tiny"]) throws -> JobQueue {
        var s = Settings()
        s.defaultModelID = "parakeet-v3"
        return JobQueue(store: try TestSupport.store(downloaded: downloaded),
                        decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()),
                        settings: SettingsBox(s),
                        engineFactory: { _, _ in engine })
    }

    private func copyFixture(into dir: URL, as name: String = "Movie.mkv") throws -> URL {
        let dst = dir.appending(path: name)
        try FileManager.default.copyItem(at: TestSupport.fixture("en.mkv"), to: dst)
        return dst
    }

    func testJobsRunOneAtATimeInOrder() async throws {
        let engine = CountingEngine()
        let q = try makeQueue(engine: engine)
        let a = await q.submit(JobRequest(input: .media(TestSupport.fixture("en.m4a")), origin: .gui))
        let b = await q.submit(JobRequest(input: .media(TestSupport.fixture("en.mkv")), origin: .gui))
        let rb = await q.result(of: b)
        let ra = await q.snapshot(a)
        XCTAssertEqual(ra?.status, .done)
        XCTAssertEqual(rb?.status, .done)
        XCTAssertEqual(rb?.modelID, "parakeet-v3")
        let maxActive = await engine.maxActive
        XCTAssertEqual(maxActive, 1)
    }

    func testDuplicateSidecarSubmitReturnsSameJob() async throws {
        let dir = try TestSupport.tempDir()
        let movie = try copyFixture(into: dir)
        let q = try makeQueue(engine: CountingEngine(delay: .milliseconds(300)))
        let r = JobRequest(input: .media(movie), language: "en", writeSidecarNextTo: movie, origin: .watcher)
        let first = await q.submit(r)
        let second = await q.submit(r)
        XCTAssertEqual(first, second)
        _ = await q.result(of: first)
    }

    func testWritesSidecarSRT() async throws {
        let dir = try TestSupport.tempDir()
        let movie = try copyFixture(into: dir)
        let q = try makeQueue(engine: CountingEngine())
        let snap = await q.run(JobRequest(input: .media(movie), writeSidecarNextTo: movie, origin: .api))
        XCTAssertEqual(snap.status, .done)
        let srtURL = dir.appending(path: "Movie.en.srt")
        XCTAssertEqual(snap.outputURL?.lastPathComponent, "Movie.en.srt")
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> "), srt)
        XCTAssertTrue(srt.contains("quick brown fox"))
    }

    func testExistingSidecarIsSkipped() async throws {
        let dir = try TestSupport.tempDir()
        let movie = try copyFixture(into: dir)
        try "x".write(to: dir.appending(path: "Movie.en.srt"), atomically: true, encoding: .utf8)
        let engine = CountingEngine()
        let q = try makeQueue(engine: engine)
        let snap = await q.run(JobRequest(input: .media(movie), language: "en", writeSidecarNextTo: movie, origin: .watcher))
        XCTAssertEqual(snap.status, .skipped("subtitle exists"))
        let calls = await engine.calls
        XCTAssertEqual(calls, 0)
    }

    func testCancelQueuedJob() async throws {
        let q = try makeQueue(engine: CountingEngine(delay: .milliseconds(500)))
        let a = await q.submit(JobRequest(input: .media(TestSupport.fixture("en.m4a")), origin: .gui))
        let b = await q.submit(JobRequest(input: .media(TestSupport.fixture("en.mkv")), origin: .gui))
        await q.cancel(b)
        let rb = await q.result(of: b)
        XCTAssertEqual(rb?.status, .cancelled)
        let ra = await q.result(of: a)
        XCTAssertEqual(ra?.status, .done)
    }

    func testCancelRunningJob() async throws {
        let q = try makeQueue(engine: CountingEngine(delay: .seconds(5)))
        let a = await q.submit(JobRequest(input: .media(TestSupport.fixture("en.m4a")), origin: .gui))
        try await Task.sleep(for: .milliseconds(800))
        await q.cancel(a)
        let ra = await q.result(of: a)
        XCTAssertEqual(ra?.status, .cancelled)
    }

    func testModelNotDownloadedFails() async throws {
        let q = try makeQueue(engine: CountingEngine(), downloaded: [])
        let snap = await q.run(JobRequest(input: .media(TestSupport.fixture("en.m4a")), origin: .gui))
        guard case .failed = snap.status else { return XCTFail("expected failure, got \(snap.status)") }
    }

    func testDetectLanguageUsesWhisper() async throws {
        let q = try makeQueue(engine: CountingEngine())
        let r = try await q.detectLanguage(.pcm16le(TestSupport.fixture("en.pcm")))
        XCTAssertEqual(r?.code, "fr")
        let none = try makeQueue(engine: CountingEngine(), downloaded: ["parakeet-v3"])
        let r2 = try await none.detectLanguage(.pcm16le(TestSupport.fixture("en.pcm")))
        XCTAssertNil(r2)
    }

    func testParakeetWordMerging() {
        let tokens: [ParakeetWords.Token] = [
            .init(text: "▁The", start: 0, end: 0.2), .init(text: "▁qu", start: 0.2, end: 0.3),
            .init(text: "ick", start: 0.3, end: 0.4), .init(text: "▁fox", start: 0.4, end: 0.6),
            .init(text: ".", start: 0.6, end: 0.65), .init(text: "▁Then", start: 2.0, end: 2.2),
        ]
        let words = ParakeetWords.words(from: tokens)
        XCTAssertEqual(words.map(\.text), [" The", " quick", " fox.", " Then"])
        XCTAssertEqual(words[1].start, 0.2); XCTAssertEqual(words[1].end, 0.4)
        let segs = ParakeetWords.segments(from: words)
        XCTAssertEqual(segs.map(\.text), ["The quick fox.", "Then"])
    }
}
