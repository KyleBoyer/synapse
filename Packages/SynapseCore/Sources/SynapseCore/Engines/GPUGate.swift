import Foundation

/// Serializes MLX inference across every engine in the process. Two models running MLX work at once can trip
/// the Metal command-buffer watchdog (seen as "GPU Timeout" with a chat reply overlapping an image generation),
/// which MLX turns into a fatal error, so work is admitted one job at a time, first come first served.
public actor GPUGate {
    public static let shared = GPUGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Runs `body` while holding the gate.
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}

/// Releases a held gate exactly once, from whichever path finishes first.
final class GateRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func callAsFunction() {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { Task { await GPUGate.shared.release() } }
    }
}
