import CryptoKit
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXLMCommon

/// Prompt-cache counters since launch, plus what is held now.
public struct PromptCacheStats: Sendable, Equatable {
    public var requests = 0, hits = 0, promptTokens = 0, cachedTokens = 0, entries = 0, bytes = 0
    /// Checkpoints read back from disk, and what the disk cache holds now (all models together).
    public var diskHits = 0, diskEntries = 0, diskBytes = 0
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
    private let disk: DiskPromptCache?
    private var diskIndex: [(tokens: [Int], url: URL)]?

    init(byteLimit: Int, minReuse: Int = 32, disk: DiskPromptCache? = nil) {
        self.byteLimit = byteLimit; self.minReuse = minReuse; self.disk = disk
    }

    var stats: Stats {
        var s = counters
        s.entries = entries.count
        s.bytes = entries.reduce(0) { $0 + $1.bytes }
        if let usage = disk?.usage() { s.diskEntries = usage.entries; s.diskBytes = usage.bytes }
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
        if let found = fromDisk(tokens, better: best?.reuse ?? 0) { return found }
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

    /// A saved checkpoint longer than what memory offers, loaded and promoted to memory.
    private func fromDisk(_ tokens: [Int], better than: Int) -> Checkpoint? {
        guard let disk else { return nil }
        let index = diskIndex ?? disk.index()
        diskIndex = index
        guard let hit = index.filter({ $0.tokens.count > than && $0.tokens.count < tokens.count
                                         && Array(tokens.prefix($0.tokens.count)) == $0.tokens })
                .max(by: { $0.tokens.count < $1.tokens.count })
        else { return nil }
        do {
            let loaded = try disk.load(hit.url, reused: hit.tokens.count)
            counters.diskHits += 1
            store(hit.tokens, .init(cache: loaded.cache.map { $0.copy() }, state: loaded.state, reused: loaded.reused))
            return loaded
        } catch {
            disk.remove(hit.url)   // unreadable: drop it rather than fail every lookup
            diskIndex?.removeAll { $0.url == hit.url }
            return nil
        }
    }

    /// Saves the memory checkpoint for `tokens` to disk once its conversation has grown by a third since the last
    /// save, replacing that one. A long agent session is then written a few times, not on every turn.
    func persist(_ tokens: [Int]) {
        guard let disk, tokens.count >= DiskPromptCache.minTokens,
              let e = entries.first(where: { $0.tokens == tokens }) else { return }
        let index = diskIndex ?? disk.index()
        let earlier = index.filter { $0.tokens.count <= tokens.count && Array(tokens.prefix($0.tokens.count)) == $0.tokens }
        guard (earlier.map(\.tokens.count).max() ?? 0) * 4 < tokens.count * 3 else { return }
        do {
            try disk.save(tokens, .init(cache: e.cache, state: e.state, reused: tokens.count))
            for old in earlier { disk.remove(old.url) }
        } catch {
            // A full disk only costs the warm start; generation is unaffected.
        }
        diskIndex = nil   // saving may have evicted others; re-read on the next lookup
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

    /// The saved checkpoints were deleted; read the folder again on the next lookup.
    func forgetDisk() { diskIndex = nil }

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

/// Checkpoints saved under `<models>/cache/<model id>/<config hash>/`, so a long system prompt stays warm across
/// unloads and relaunches. Each entry is `<sha256>.safetensors` (the KV state, with the model state) plus
/// `<sha256>.tokens` (the prompt it holds, Int32 little-endian). The folder name changes when the model's config does,
/// so stale checkpoints are never loaded; the size limit evicts them with the rest, oldest use first.
struct DiskPromptCache: Sendable {
    let dir: URL
    /// The whole `<models>/cache` folder, which the byte limit covers (all models together).
    let root: URL
    let byteLimit: Int
    /// Shorter checkpoints are cheap to recompute and not worth a file.
    static let minTokens = 1024

    /// `variant` separates checkpoints that cannot be mixed (the KV precision they were built at).
    init(root: URL, modelID: String, modelFolder: URL, variant: String = "full", byteLimit: Int) {
        self.root = root
        self.byteLimit = byteLimit
        let config = ((try? Data(contentsOf: modelFolder.appending(path: "config.json"))) ?? Data()) + Data(variant.utf8)
        let hash = SHA256.hash(data: config).prefix(6).map { String(format: "%02x", $0) }.joined()
        dir = Self.folder(root: root)(modelID).appending(path: hash, directoryHint: .isDirectory)
    }

    /// One model's checkpoints, across config versions.
    static func folder(root: URL) -> (String) -> URL {
        { id in root.appending(path: id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory) }
    }

    static func name(_ tokens: [Int]) -> String {
        let bytes = tokens.flatMap { withUnsafeBytes(of: Int32(truncatingIfNeeded: $0).littleEndian, Array.init) }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Token lists of every checkpoint in this model's folder.
    func index() -> [(tokens: [Int], url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "tokens" }.compactMap { f in
            guard let data = try? Data(contentsOf: f), data.count % 4 == 0 else { return nil }
            let tokens = data.withUnsafeBytes { raw in raw.bindMemory(to: Int32.self).map { Int(Int32(littleEndian: $0)) } }
            return (tokens, f.deletingPathExtension().appendingPathExtension("safetensors"))
        }
    }

    func contains(_ tokens: [Int]) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: Self.name(tokens) + ".safetensors").path)
    }

    /// Writes the checkpoint (tokens file last, so a half-written entry is never indexed), then trims the folder.
    func save(_ tokens: [Int], _ checkpoint: PromptCache.Checkpoint) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appending(path: Self.name(tokens))
        let tmp = dir.appending(path: ".\(UUID().uuidString).safetensors")
        try savePromptCache(url: tmp, cache: checkpoint.cache, state: checkpoint.state)
        _ = try? FileManager.default.removeItem(at: base.appendingPathExtension("safetensors"))
        try FileManager.default.moveItem(at: tmp, to: base.appendingPathExtension("safetensors"))
        let bytes = tokens.flatMap { withUnsafeBytes(of: Int32(truncatingIfNeeded: $0).littleEndian, Array.init) }
        try Data(bytes).write(to: base.appendingPathExtension("tokens"), options: .atomic)
        evict()
    }

    func load(_ url: URL, reused: Int) throws -> PromptCache.Checkpoint {
        let snapshot = try loadPromptCacheSnapshot(url: url)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)   // LRU by use
        return .init(cache: snapshot.cache, state: snapshot.state, reused: reused)
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("tokens"))
    }

    /// Total size of every model's checkpoints, and how many there are.
    func usage() -> (bytes: Int, entries: Int) {
        let files = Self.checkpoints(in: root)
        return (files.reduce(0) { $0 + $1.bytes }, files.count)
    }

    private func evict() {
        var files = Self.checkpoints(in: root).sorted { $0.used < $1.used }
        var total = files.reduce(0) { $0 + $1.bytes }
        while total > byteLimit, !files.isEmpty {
            let f = files.removeFirst()
            remove(f.url)
            total -= f.bytes
        }
    }

    private static func checkpoints(in root: URL) -> [(url: URL, bytes: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "safetensors" && !$0.lastPathComponent.hasPrefix(".") }
            .map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
            }
    }
}
