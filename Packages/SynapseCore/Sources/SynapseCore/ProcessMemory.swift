import Darwin

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

    /// The share of memory (0-100) macOS counts as available, the figure its own memory killer goes by.
    public static func systemAvailablePercent() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
    }

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
