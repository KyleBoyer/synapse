import Foundation
@preconcurrency import MLX
@preconcurrency import MLXLMCommon

/// Prompt-cache counters since launch, plus what is held now.
public struct PromptCacheStats: Sendable, Equatable {
    public var requests = 0, hits = 0, promptTokens = 0, cachedTokens = 0, entries = 0, bytes = 0
    public init() {}
}

/// KV states keyed by the exact prompt tokens each one represents, for one loaded model.
///
/// Hybrid models (Qwen3.5's GatedDeltaNet layers) keep recurrent state that cannot be rewound, so a stored entry is
/// reused only when its tokens are a prefix of the new prompt. ChatService stores checkpoints at the end of the
/// conversation history (before the generation prompt), which every follow-up turn starts with. Pure-attention models
/// can also be rewound to the longest common prefix.
actor PromptCache {
    typealias Stats = PromptCacheStats

    /// A KV state handed between the cache and a generation. Its caches are always fresh `copy()`s and the model
    /// state holds immutable MLX arrays, so a checkpoint is never shared with anything that mutates it; the
    /// compiler cannot see that `copy()` breaks the link, hence the unchecked conformance.
    struct Checkpoint: @unchecked Sendable {
        var cache: [KVCache]
        var state: LMOutput.State?
        /// Prompt tokens this checkpoint already holds.
        var reused: Int
    }

    private struct Entry {
        var tokens: [Int]
        var cache: [KVCache]
        var state: LMOutput.State?
        var bytes: Int
        var lastUsed: Date
    }

    private var entries: [Entry] = []
    private var counters = Stats()
    private(set) var byteLimit: Int
    private let minReuse: Int

    init(byteLimit: Int, minReuse: Int = 32) {
        self.byteLimit = byteLimit; self.minReuse = minReuse
    }

    var stats: Stats {
        var s = counters
        s.entries = entries.count
        s.bytes = entries.reduce(0) { $0 + $1.bytes }
        return s
    }

    /// The longest reusable entry for `tokens`, as a copy (requests never share a mutable cache). Always leaves at
    /// least one token to feed, since generation needs input.
    func lookup(_ tokens: [Int]) -> Checkpoint? {
        var best: (index: Int, reuse: Int)?
        for (i, e) in entries.enumerated() {
            let common = Self.commonPrefix(e.tokens, tokens)
            let reuse: Int
            if common == e.tokens.count, common < tokens.count {
                reuse = common
            } else if common >= minReuse, canTrimPromptCache(e.cache) {
                reuse = min(common, tokens.count - 1)
            } else {
                continue
            }
            if reuse > (best?.reuse ?? 0) { best = (i, reuse) }
        }
        guard let best else { return nil }
        entries[best.index].lastUsed = Date()
        let e = entries[best.index]
        let hit = Checkpoint(cache: e.cache.map { $0.copy() }, state: e.state, reused: best.reuse)
        if best.reuse < e.tokens.count { trimPromptCache(hit.cache, numTokens: e.tokens.count - best.reuse) }
        return hit
    }

    /// Keeps `cache` (already a copy) as the state after `tokens`. A conversation keeps one entry: entries whose tokens
    /// are a prefix of the new one are dropped.
    func store(_ tokens: [Int], _ checkpoint: Checkpoint) {
        entries.removeAll { $0.tokens.count <= tokens.count && Array(tokens.prefix($0.tokens.count)) == $0.tokens }
        let bytes = checkpoint.cache.reduce(0) { $0 + $1.state.reduce(0) { $0 + $1.nbytes } }
        entries.append(Entry(tokens: tokens, cache: checkpoint.cache, state: checkpoint.state, bytes: bytes, lastUsed: Date()))
        evict(to: byteLimit)
    }

    func record(prompt: Int, cached: Int) {
        counters.requests += 1
        if cached > 0 { counters.hits += 1 }
        counters.promptTokens += prompt
        counters.cachedTokens += cached
    }

    func setLimit(_ bytes: Int) {
        byteLimit = bytes
        evict(to: bytes)
    }

    func clear() { entries.removeAll() }

    private func evict(to limit: Int) {
        while entries.reduce(0, { $0 + $1.bytes }) > limit,
              let oldest = entries.indices.min(by: { entries[$0].lastUsed < entries[$1].lastUsed }) {
            entries.remove(at: oldest)
        }
    }

    static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }
}
