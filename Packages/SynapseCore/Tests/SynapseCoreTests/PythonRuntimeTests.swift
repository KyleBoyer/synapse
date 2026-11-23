import XCTest
@testable import SynapseCore

final class PythonRuntimeTests: XCTestCase {
    func testStoreRootWalksUpToManifest() throws {
        let root = try TestSupport.tempDir()
        try Data("{}".utf8).write(to: root.appending(path: "manifest.json"))
        let model = root.appending(path: "mlx/org/model", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        XCTAssertEqual(try PythonRuntime.storeRoot(above: model).standardizedFileURL, root.standardizedFileURL)

        let orphan = try TestSupport.tempDir().appending(path: "a/b", directoryHint: .isDirectory)
        XCTAssertThrowsError(try PythonRuntime.storeRoot(above: orphan))
    }

    func testRunStreamingSplitsOnCarriageReturnAndNewline() async throws {
        let lines = LockedLines()
        try await PythonRuntime.runStreaming(URL(fileURLWithPath: "/usr/bin/printf"), ["a\\rb\\nc"], env: [:]) { lines.add($0) }
        XCTAssertEqual(lines.value, ["a", "b", "c"])
    }

    func testRunStreamingKillsToolOverTheMemoryLimit() async throws {
        let started = ContinuousClock.now
        do {
            try await PythonRuntime.runStreaming(URL(fileURLWithPath: "/bin/sleep"), ["60"], env: [:], memoryLimit: 1) { _ in }
            XCTFail("expected the tool to be stopped")
        } catch {
            XCTAssertTrue("\(error)".contains("GPU can hold"), "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        XCTAssertGreaterThan(ProcessMemory.gpuWorkingSet, 1 << 30)
    }

    func testInstallIsIdempotent() async throws {
        guard ProcessInfo.processInfo.environment["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let root = try TestSupport.tempDir()
        let spec = PythonRuntime.Spec(name: "probe", requirements: ["six==1.17.0"])
        _ = try await PythonRuntime.shared.ensureInstalled(spec, storeRoot: root)
        let started = Date()
        let ready = try await PythonRuntime.shared.ensureInstalled(spec, storeRoot: root)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let p = Process()
        p.executableURL = ready.python; p.arguments = ["-c", "import six"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
