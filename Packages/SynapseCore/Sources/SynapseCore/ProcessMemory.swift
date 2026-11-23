import Darwin
import Foundation
import Metal

/// Physical memory of helper processes (llama.cpp, mlx-vlm, Python sidecars), as Activity Monitor's Memory column
/// counts it. Helpers run behind a watchdog parent, so the whole process tree is summed.
public enum ProcessMemory {
    public static func footprint(tree root: pid_t) -> Int? {
        guard let own = footprint(root) else { return nil }
        return own + children(of: root).reduce(0) { $0 + (footprint(tree: $1) ?? 0) }
    }

    static func footprint(_ pid: pid_t) -> Int? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Int(info.ri_phys_footprint) : nil
    }

    /// How much memory the GPU can use before macOS can't keep the screen running (Metal's recommended working set,
    /// about 11-12 GB on a 16 GB Mac). Past it, GPU memory is paged and WindowServer stalls until the Mac restarts.
    public static let gpuWorkingSet: Int = MTLCreateSystemDefaultDevice().map { Int($0.recommendedMaxWorkingSetSize) }
        ?? Int(ProcessInfo.processInfo.physicalMemory / 4 * 3)

    static func kill(tree root: pid_t) {
        for child in children(of: root) { kill(tree: child) }
        Darwin.kill(root, SIGKILL)
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(pids.prefix(Int(n))) : []
    }
}
