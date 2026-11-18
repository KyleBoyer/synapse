import XCTest
@testable import SynapseCore

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [JobRequest] = []
    func add(_ r: JobRequest) { lock.lock(); items.append(r); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return items.map { $0.input.url.lastPathComponent } }
}

final class FolderWatcherTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func make(_ name: String, bytes: Int = 10) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(count: bytes))
    }
    func watcher(_ c: Collector, stability: Duration = .milliseconds(200)) -> FolderWatcher {
        FolderWatcher(submit: { c.add($0) }, stabilityInterval: stability, rescanInterval: .seconds(1))
    }
    func until(_ timeout: Double, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { break }
            try? await Task.sleep(for: .milliseconds(50)) }
    }
    let folder = { (d: URL) in WatchFolder(path: d.path, language: "en") }

    func testIsCandidate() {
        let c = { FolderWatcher.isCandidate(URL(fileURLWithPath: $0)) }
        XCTAssertTrue(c("/a/b/Movie.MKV"))
        XCTAssertTrue(c("/a/song.flac"))
        XCTAssertFalse(c("/a/notes.txt"))
        XCTAssertFalse(c("/a/.hidden.mkv"))
        XCTAssertFalse(c("/a/.dir/x.mkv"))
        XCTAssertFalse(c("/a/x.mkv.part"))
        XCTAssertFalse(c("/a/x.mkv.!qB"))
        XCTAssertFalse(c("/a/@eaDir/x.mkv"))
        XCTAssertFalse(c("/a/#recycle/x.mkv"))
    }

    func testInitialScanSkipsSidecar() async {
        make("A.mkv"); make("Movie.mkv"); make("Movie.en.srt"); make("readme.txt")
        let c = Collector(), w = watcher(c)
        await w.update(folders: [folder(dir)], paused: false)
        await until(3) { c.paths.contains("A.mkv") }
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(c.paths, ["A.mkv"])
        await w.stop()
    }

    func testNewFileSubmittedOnce() async {
        let c = Collector(), w = watcher(c)
        await w.update(folders: [folder(dir)], paused: false)
        try? await Task.sleep(for: .milliseconds(300))
        make("New.mp4")
        await until(8) { !c.paths.isEmpty }
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(c.paths, ["New.mp4"])
        await w.stop()
    }

    func testGrowingFileWaits() async throws {
        make("G.mkv", bytes: 5)
        // Writes come every 100 ms; a 1 s window keeps a slow CI runner's stretched sleeps from looking like a finished file.
        let c = Collector(), w = watcher(c, stability: .seconds(1))
        await w.update(folders: [folder(dir)], paused: false)
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("G.mkv"))
        for _ in 0..<8 {
            try h.seekToEnd(); try h.write(contentsOf: Data(count: 100))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(c.paths.isEmpty)
        }
        try h.close()
        await until(6) { !c.paths.isEmpty }
        XCTAssertEqual(c.paths, ["G.mkv"])
        await w.stop()
    }

    func testPausedSubmitsNothing() async {
        make("P.mkv")
        let c = Collector(), w = watcher(c)
        await w.update(folders: [folder(dir)], paused: true)
        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(c.paths.isEmpty)
    }
}
