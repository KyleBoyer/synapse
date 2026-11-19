import XCTest
@testable import SynapseCore

final class ModelManagerTests: XCTestCase {
    actor Log {
        var loads: [String] = []
        var unloads: [String] = []
        func load(_ id: String) { loads.append(id) }
        func unload(_ id: String) { unloads.append(id) }
    }

    private func loader(_ id: String, _ log: Log) -> @Sendable () async throws -> (String, unload: @Sendable () async -> Void) {
        { await log.load(id); return ("model-\(id)", unload: { await log.unload(id) }) }
    }

    func testLoadsOnceAndReuses() async throws {
        let log = Log()
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: nil))
        let a = try await m.lease("a", as: String.self, estimatedBytes: 10, load: loader("a", log))
        let b = try await m.lease("a", as: String.self, estimatedBytes: 10, load: loader("a", log))
        XCTAssertEqual(a.value, "model-a"); XCTAssertEqual(b.value, "model-a")
        let loads = await log.loads
        XCTAssertEqual(loads, ["a"])
    }

    func testEvictsLeastRecentlyUsedIdleModelToFitBudget() async throws {
        let log = Log()
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: nil))
        try await m.use("a", as: String.self, estimatedBytes: 50, load: loader("a", log)) { _ in }
        try await m.use("b", as: String.self, estimatedBytes: 40, load: loader("b", log)) { _ in }
        try await Task.sleep(for: .milliseconds(20))
        try await m.use("a", as: String.self, estimatedBytes: 50, load: loader("a", log)) { _ in }  // a is now most recent
        try await Task.sleep(for: .milliseconds(20))
        try await m.use("c", as: String.self, estimatedBytes: 40, load: loader("c", log)) { _ in }
        let unloads = await log.unloads
        XCTAssertEqual(unloads, ["b"])
        let resident = await m.residents().map(\.id)
        XCTAssertEqual(resident, ["a", "c"])
        let over = await m.overcommitted
        XCTAssertFalse(over)
    }

    func testLeasedModelIsNeverEvictedAndOvercommitIsReported() async throws {
        let log = Log()
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: nil))
        let a = try await m.lease("a", as: String.self, estimatedBytes: 80, load: loader("a", log))
        try await m.use("b", as: String.self, estimatedBytes: 80, load: loader("b", log)) { _ in }
        let unloads = await log.unloads
        XCTAssertEqual(unloads, [])
        let over = await m.overcommitted
        XCTAssertTrue(over)
        let refused = await m.unload("a")
        XCTAssertFalse(refused)
        a.release()
        try await Task.sleep(for: .milliseconds(50))
        let ok = await m.unload("a")
        XCTAssertTrue(ok)
    }

    func testMeasuredSizeReplacesEstimateAndDrivesEviction() async throws {
        let log = Log()
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: nil))
        // Estimated at 90, but it measures 30: a 60-byte model must then fit without evicting it.
        try await m.use("a", as: String.self, estimatedBytes: 90, measure: { _ in 30 }, load: loader("a", log)) { _ in }
        let a = await m.residents().first { $0.id == "a" }
        XCTAssertEqual(a?.bytes, 30); XCTAssertEqual(a?.measured, true)
        try await m.use("b", as: String.self, estimatedBytes: 60, load: loader("b", log)) { _ in }
        let unloads = await log.unloads
        XCTAssertEqual(unloads, [])
        let b = await m.residents().first { $0.id == "b" }
        XCTAssertEqual(b?.measured, false)
    }

    func testPinnedModelsSurviveIdlenessAndAreEvictedLast() async throws {
        let log = Log()
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: .milliseconds(10), pinned: ["a"]))
        // Leases are released on their own task; let each land before the next load looks for idle models.
        func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
        try await m.use("a", as: String.self, estimatedBytes: 40, load: loader("a", log)) { _ in }
        try await settle()
        try await m.use("b", as: String.self, estimatedBytes: 40, load: loader("b", log)) { _ in }
        try await settle()
        // "a" is older, but pinned: making room for "c" takes "b".
        try await m.use("c", as: String.self, estimatedBytes: 40, load: loader("c", log)) { _ in }
        var unloads = await log.unloads
        XCTAssertEqual(unloads, ["b"])
        try await Task.sleep(for: .milliseconds(20))
        await m.reapIdle()
        unloads = await log.unloads
        XCTAssertEqual(unloads, ["b", "c"], "the reaper leaves pinned models")
        // With only pinned models idle, they still give way rather than overcommit.
        try await m.use("d", as: String.self, estimatedBytes: 80, load: loader("d", log)) { _ in }
        unloads = await log.unloads
        XCTAssertEqual(unloads, ["b", "c", "a"])
    }

    func testProcessTreeFootprintCountsChildren() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5 & wait"]
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(ProcessMemory.children(of: p.processIdentifier).count, 1)
        let own = try XCTUnwrap(ProcessMemory.footprint(p.processIdentifier))
        let tree = try XCTUnwrap(ProcessMemory.footprint(tree: p.processIdentifier))
        XCTAssertGreaterThan(tree, own)
        XCTAssertNil(ProcessMemory.footprint(tree: -1))
    }

    func testConcurrentLeasesShareOneLoad() async throws {
        let log = Log()
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: nil))
        let slow: @Sendable () async throws -> (String, unload: @Sendable () async -> Void) = {
            await log.load("s"); try await Task.sleep(for: .milliseconds(100)); return ("s", unload: {})
        }
        async let x = m.lease("s", as: String.self, estimatedBytes: 10, load: slow)
        async let y = m.lease("s", as: String.self, estimatedBytes: 10, load: slow)
        _ = try await (x, y)
        let loads = await log.loads
        XCTAssertEqual(loads.count, 1)
    }

    func testIdleReaperUnloads() async throws {
        let log = Log()
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: .seconds(0)))
        try await m.use("a", as: String.self, estimatedBytes: 10, load: loader("a", log)) { _ in }
        try await Task.sleep(for: .milliseconds(20))
        await m.reapIdle()
        let unloads = await log.unloads
        XCTAssertEqual(unloads, ["a"])
    }

    func testFailedLoadIsNotCached() async throws {
        let m = ModelManager(config: .init(budgetBytes: 100, idleUnloadAfter: nil))
        struct Boom: Error {}
        do {
            _ = try await m.lease("x", as: String.self, estimatedBytes: 10) { throw Boom() }
            XCTFail("expected throw")
        } catch is Boom {}
        let loaded = await m.isLoaded("x")
        XCTAssertFalse(loaded)
    }
}

final class SettingsMigrationTests: XCTestCase {
    func testOldSettingsJSONKeepsValuesAndGainsNewDefaults() throws {
        let old = #"{"defaultModelID":"whisper-tiny","serverEnabled":false,"port":9100,"allowLAN":true,"apiKey":"KEEP-ME","libraryRoots":["/media"],"watchFolders":[],"watchingPaused":false,"cue":{"maxLineChars":40,"maxLines":2,"maxDuration":7,"maxGap":1,"minDuration":0.5}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(s.apiKey, "KEEP-ME")
        XCTAssertEqual(s.port, 9100)
        XCTAssertEqual(s.libraryRoots, ["/media"])
        XCTAssertEqual(s.idleUnloadMinutes, 15)
        XCTAssertNil(s.memoryBudgetGB)
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
    }
}
