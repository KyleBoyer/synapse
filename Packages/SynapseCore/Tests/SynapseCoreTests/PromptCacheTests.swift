import MLX
import MLXLMCommon
import XCTest
@testable import SynapseCore

/// Bookkeeping only: caches are built from shapes, never evaluated, so no GPU or metallib is needed.
final class PromptCacheTests: XCTestCase {
    /// A one-layer attention cache holding `n` tokens of 4-dim keys and values.
    private func attention(_ n: Int) -> [KVCache] {
        let c = KVCacheSimple()
        _ = c.update(keys: MLXArray.zeros([1, 1, n, 4]), values: MLXArray.zeros([1, 1, n, 4]))
        return [c]
    }

    /// Attention plus a recurrent layer, like Qwen3.5: not trimmable.
    private func hybrid(_ n: Int) -> [KVCache] {
        let m = MambaCache()
        m.state = [MLXArray.zeros([1, 4]), MLXArray.zeros([1, 4])]
        return attention(n) + [m]
    }

    private func checkpoint(_ cache: [KVCache], _ n: Int) -> PromptCache.Checkpoint { .init(cache: cache, state: nil, reused: n) }

    func testLongestStrictPrefixWinsAndIsACopy() async throws {
        let pc = PromptCache(byteLimit: 1 << 30)
        await pc.store(Array(0..<10), checkpoint(hybrid(10), 10))
        await pc.store(Array(100..<140), checkpoint(hybrid(40), 40))   // another conversation
        let hitFound = await pc.lookup(Array(0..<10) + [7, 8, 9])
        let hit = try XCTUnwrap(hitFound)
        XCTAssertEqual(hit.reused, 10)
        _ = hit.cache[0].update(keys: MLXArray.zeros([1, 1, 3, 4]), values: MLXArray.zeros([1, 1, 3, 4]))
        XCTAssertEqual(hit.cache[0].offset, 13)
        // The stored entry is untouched: a second lookup still starts at 10.
        let againFound = await pc.lookup(Array(0..<12))
        let again = try XCTUnwrap(againFound)
        XCTAssertEqual(again.cache[0].offset, 10)
    }

    func testAnIdenticalPromptStillLeavesATokenToFeed() async {
        let pc = PromptCache(byteLimit: 1 << 30)
        await pc.store(Array(0..<10), checkpoint(hybrid(10), 10))
        let none = await pc.lookup(Array(0..<10))
        XCTAssertNil(none, "a hybrid cache cannot be rewound, and an exact match leaves nothing to feed")
    }

    func testRecurrentCachesAreNeverRewound() async {
        let pc = PromptCache(byteLimit: 1 << 30, minReuse: 4)
        await pc.store(Array(0..<40), checkpoint(hybrid(40), 40))
        let edited = Array(0..<20) + [999] + Array(21..<40)   // diverges at 20
        let none = await pc.lookup(edited)
        XCTAssertNil(none)
    }

    func testAttentionCachesRewindToTheCommonPrefix() async throws {
        let pc = PromptCache(byteLimit: 1 << 30, minReuse: 4)
        await pc.store(Array(0..<40), checkpoint(attention(40), 40))
        let hitFound = await pc.lookup(Array(0..<20) + [999])
        let hit = try XCTUnwrap(hitFound)
        XCTAssertEqual(hit.reused, 20)
        XCTAssertEqual(hit.cache[0].offset, 20)
        let tooShort = await pc.lookup(Array(0..<3) + [999])
        XCTAssertNil(tooShort, "below minReuse")
    }

    func testAConversationKeepsOneEntryAndEvictionHonorsTheLimit() async {
        let one = attention(10).reduce(0) { $0 + $1.state.reduce(0) { $0 + $1.nbytes } }
        let pc = PromptCache(byteLimit: one * 5 / 2)   // room for 25 tokens
        await pc.store(Array(0..<10), checkpoint(attention(10), 10))
        await pc.store(Array(0..<20), checkpoint(attention(20), 20))   // the same conversation, one turn later
        var stats = await pc.stats
        XCTAssertEqual(stats.entries, 1)
        await pc.store(Array(500..<510), checkpoint(attention(10), 10))
        stats = await pc.stats
        XCTAssertEqual(stats.entries, 1, "30 tokens of data exceed the 25-token limit, so the older entry goes")
        XCTAssertLessThanOrEqual(stats.bytes, one * 5 / 2)
    }

    func testCountersAccumulate() async {
        let pc = PromptCache(byteLimit: 1 << 30)
        await pc.record(prompt: 100, cached: 0)
        await pc.record(prompt: 120, cached: 90)
        let s = await pc.stats
        XCTAssertEqual(s.requests, 2); XCTAssertEqual(s.hits, 1)
        XCTAssertEqual(s.promptTokens, 220); XCTAssertEqual(s.cachedTokens, 90)
    }
}

/// The disk tier writes real safetensors files, so these evaluate arrays, on the CPU (no metallib needed).
final class DiskPromptCacheTests: XCTestCase {
    private func folder(config: String) throws -> URL {
        let f = try TestSupport.tempDir()
        try Data(config.utf8).write(to: f.appending(path: "config.json"))
        return f
    }

    private func checkpoint(_ n: Int) -> PromptCache.Checkpoint {
        let c = KVCacheSimple()
        _ = c.update(keys: MLXArray.ones([1, 1, n, 4]), values: MLXArray.ones([1, 1, n, 4]))
        return .init(cache: [c], state: nil, reused: n)
    }

    func testSavedCheckpointIsFoundAfterTheMemoryCacheIsGone() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let root = try TestSupport.tempDir(), model = try folder(config: "{\"a\":1}")
            let disk = DiskPromptCache(root: root, modelID: "org/m", modelFolder: model, byteLimit: 1 << 30)
            let tokens = Array(0..<1100)
            let first = PromptCache(byteLimit: 1 << 30, disk: disk)
            await first.store(tokens, checkpoint(1100))
            await first.persist(tokens)
            XCTAssertTrue(disk.contains(tokens))

            // A new cache (the model was unloaded, or the app relaunched) finds it on disk.
            let second = PromptCache(byteLimit: 1 << 30, disk: disk)
            let found = await second.lookup(tokens + [5, 6])
            let hit = try XCTUnwrap(found)
            XCTAssertEqual(hit.reused, 1100)
            XCTAssertEqual(hit.cache[0].offset, 1100)
            let stats = await second.stats
            XCTAssertEqual(stats.diskHits, 1); XCTAssertEqual(stats.entries, 1, "promoted to memory")
            XCTAssertEqual(stats.diskEntries, 1)

            // A changed model config means another folder: the old checkpoint is never offered.
            let changed = DiskPromptCache(root: root, modelID: "org/m", modelFolder: try folder(config: "{\"a\":2}"), byteLimit: 1 << 30)
            let none = await PromptCache(byteLimit: 1 << 30, disk: changed).lookup(tokens + [5])
            XCTAssertNil(none)
        }
    }

    func testAGrowingConversationIsSavedOnlyWhenItGrowsByAThird() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let root = try TestSupport.tempDir(), model = try folder(config: "{}")
            let disk = DiskPromptCache(root: root, modelID: "m", modelFolder: model, byteLimit: 1 << 30)
            let pc = PromptCache(byteLimit: 1 << 30, disk: disk)
            for n in [1100, 1200, 1300, 1500] {
                let t = Array(0..<n)
                await pc.store(t, checkpoint(n)); await pc.persist(t)
            }
            XCTAssertEqual(disk.usage().entries, 1, "one file per conversation")
            XCTAssertTrue(disk.contains(Array(0..<1500)), "1500 is more than a third past 1100")
            XCTAssertFalse(disk.contains(Array(0..<1300)))
        }
    }

    func testShortPromptsAreNotSavedAndTheLimitEvictsOldest() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let root = try TestSupport.tempDir(), model = try folder(config: "{}")
            let probe = DiskPromptCache(root: root, modelID: "m", modelFolder: model, byteLimit: 1 << 30)
            let pc = PromptCache(byteLimit: 1 << 30, disk: probe)
            await pc.store(Array(0..<100), checkpoint(100))
            await pc.persist(Array(0..<100))
            XCTAssertEqual(probe.usage().entries, 0, "below the minimum length")

            let a = Array(0..<1100), b = Array(5000..<6100)
            await pc.store(a, checkpoint(1100)); await pc.persist(a)
            let one = probe.usage().bytes
            // Room for one checkpoint: saving b evicts a.
            let tight = PromptCache(byteLimit: 1 << 30, disk: DiskPromptCache(root: root, modelID: "m", modelFolder: model, byteLimit: one + one / 2))
            await tight.store(b, checkpoint(1100)); await tight.persist(b)
            XCTAssertEqual(probe.usage().entries, 1)
            XCTAssertTrue(probe.contains(b)); XCTAssertFalse(probe.contains(a))
        }
    }
}
