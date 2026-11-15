import Foundation
import MLX
import Synchronization

/// A model held in memory by the ModelManager. `unload` releases framework-side resources;
/// dropping the last reference must then free the weights.
public struct ResidentInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let bytes: Int
    public let leases: Int
    public let lastUsed: Date
    public let loadedAt: Date
}

/// Shared loader/unloader for every model kind (transcription, chat, image, speech).
///
/// Accounting uses each model's estimated resident size. Before a load, idle models are evicted
/// least-recently-used first until the new model fits the budget. Models with active leases are
/// never evicted. When nothing more can be evicted the load proceeds anyway (overcommit), letting
/// macOS page; `overcommitted` reports that so the UI can warn.
public actor ModelManager {
    public struct Config: Sendable, Equatable {
        public var budgetBytes: Int
        public var idleUnloadAfter: Duration?

        public init(budgetBytes: Int, idleUnloadAfter: Duration? = .seconds(15 * 60)) {
            self.budgetBytes = budgetBytes; self.idleUnloadAfter = idleUnloadAfter
        }

        /// 75% of physical memory, leaving room for the OS and the app.
        public static var `default`: Config {
            Config(budgetBytes: Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.75))
        }
    }

    private final class Entry: @unchecked Sendable {
        let value: any Sendable
        let bytes: Int
        let unload: @Sendable () async -> Void
        var leases = 0
        var lastUsed = Date()
        let loadedAt = Date()
        init(value: any Sendable, bytes: Int, unload: @escaping @Sendable () async -> Void) {
            self.value = value; self.bytes = bytes; self.unload = unload
        }
    }

    private var config: Config
    private var entries: [String: Entry] = [:]
    private var loading: [String: Task<Entry, Error>] = [:]
    private var reaper: Task<Void, Never>?
    private let afterUnload: @Sendable () -> Void
    public private(set) var overcommitted = false

    /// `afterUnload` runs after any model is released (the app clears MLX's buffer cache there).
    public init(config: Config = .default, afterUnload: @escaping @Sendable () -> Void = {}) {
        self.config = config
        self.afterUnload = afterUnload
    }

    /// The app's manager: frees MLX's buffer cache after each unload so memory returns to the system.
    public static func forApp(config: Config) -> ModelManager {
        ModelManager(config: config, afterUnload: { MLX.Memory.clearCache() })
    }

    public func update(config: Config) {
        self.config = config
        startReaper()
    }

    public var residentBytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    public func residents() -> [ResidentInfo] {
        entries.map { ResidentInfo(id: $0.key, bytes: $0.value.bytes, leases: $0.value.leases,
                                   lastUsed: $0.value.lastUsed, loadedAt: $0.value.loadedAt) }
            .sorted { $0.id < $1.id }
    }

    public func isLoaded(_ id: String) -> Bool { entries[id] != nil }

    /// Returns a lease on the model, loading it if needed. Call `release()` when done.
    public func lease<T: Sendable>(_ id: String, as type: T.Type = T.self, estimatedBytes: Int,
                                   load: @escaping @Sendable () async throws -> (T, unload: @Sendable () async -> Void))
        async throws -> ModelLease<T>
    {
        startReaper()
        let entry: Entry
        if let e = entries[id] {
            entry = e
        } else if let t = loading[id] {
            entry = try await t.value
        } else {
            await makeRoom(for: estimatedBytes, excluding: id)
            let task = Task<Entry, Error> {
                let (value, unload) = try await load()
                return Entry(value: value, bytes: estimatedBytes, unload: unload)
            }
            loading[id] = task
            defer { loading[id] = nil }
            entry = try await task.value
            entries[id] = entry
        }
        guard let value = entry.value as? T else {
            throw EngineError.unsupported("Model \(id) is loaded as a different type")
        }
        entry.leases += 1
        entry.lastUsed = Date()
        return ModelLease(value: value) { [weak self] in
            Task { await self?.release(id) }
        }
    }

    /// Scoped use: lease, run, release.
    public func use<T: Sendable, R: Sendable>(_ id: String, as type: T.Type = T.self, estimatedBytes: Int,
                                              load: @escaping @Sendable () async throws -> (T, unload: @Sendable () async -> Void),
                                              _ body: (T) async throws -> R) async throws -> R {
        let lease = try await lease(id, as: type, estimatedBytes: estimatedBytes, load: load)
        defer { lease.release() }
        return try await body(lease.value)
    }

    /// Unloads an idle model. Returns false if it is in use.
    @discardableResult
    public func unload(_ id: String) async -> Bool {
        guard let e = entries[id] else { return true }
        guard e.leases == 0 else { return false }
        entries[id] = nil
        await e.unload()
        afterUnload()
        recomputeOvercommit()
        return true
    }

    public func unloadAllIdle() async {
        for id in entries.filter({ $0.value.leases == 0 }).map(\.key) { await unload(id) }
    }

    private func release(_ id: String) {
        guard let e = entries[id] else { return }
        e.leases = max(0, e.leases - 1)
        e.lastUsed = Date()
    }

    private func makeRoom(for bytes: Int, excluding id: String) async {
        while residentBytes + bytes > config.budgetBytes {
            guard let victim = entries.filter({ $0.value.leases == 0 && $0.key != id })
                .min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
            await unload(victim)
        }
        overcommitted = residentBytes + bytes > config.budgetBytes
    }

    private func recomputeOvercommit() { overcommitted = residentBytes > config.budgetBytes }

    private func startReaper() {
        guard reaper == nil, let ttl = config.idleUnloadAfter else { return }
        let interval = min(ttl, .seconds(60))
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.reapIdle()
            }
        }
    }

    func reapIdle() async {
        guard let ttl = config.idleUnloadAfter else { return }
        let cutoff = Date().addingTimeInterval(-Double(ttl.components.seconds))
        for (id, e) in entries where e.leases == 0 && e.lastUsed < cutoff { await unload(id) }
    }
}

/// A handle that keeps a model resident. `release()` is idempotent.
public final class ModelLease<T: Sendable>: Sendable {
    public let value: T
    private let onRelease: @Sendable () -> Void
    private let released = Mutex(false)

    init(value: T, onRelease: @escaping @Sendable () -> Void) {
        self.value = value; self.onRelease = onRelease
    }

    public func release() {
        let first = released.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { onRelease() }
    }

    deinit { release() }
}

