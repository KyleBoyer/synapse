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
