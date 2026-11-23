import CryptoKit
import Foundation
import os

/// Managed Python runtimes: `<store root>/runtimes/<name>/{bin/uv, pythons, venv, uvcache}`.
/// Installation is idempotent (marker file written last) and serialized across callers.
actor PythonRuntime {
    static let shared = PythonRuntime()
    static let uvVersion = "0.8.22"
    static let uvSHA256 = "3f61099e261e449527141dbf125629fab33ad696468c8c90cebbac40185a306c"
    static let log = Logger(subsystem: "synapse", category: "python-runtime")

    struct Spec: Sendable { let name: String; let requirements: [String]; var python = "3.12" }
    struct Ready: Sendable { let dir: URL; let python: URL }

    /// Walks up from a model folder to the directory holding manifest.json.
    static func storeRoot(above folder: URL) throws -> URL {
        var dir = folder.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "manifest.json").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        throw MFluxError.runtime("Could not locate the model store root above \(folder.path).")
    }

    func ensureInstalled(_ spec: Spec, storeRoot: URL) async throws -> Ready {
        let dir = storeRoot.appending(path: "runtimes/\(spec.name)", directoryHint: .isDirectory)
        let fm = FileManager.default
        let venv = dir.appending(path: "venv", directoryHint: .isDirectory)
        let python = venv.appending(path: "bin/python")
        let marker = dir.appending(path: "installed.txt")
        let want = spec.requirements.joined(separator: " ")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let installed = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == want
        if !(installed && fm.isExecutableFile(atPath: python.path)) {
            let started = Date()
            Self.log.info("Installing \(want, privacy: .public) into \(dir.path, privacy: .public)")
            let uv = try await locateUV(in: dir)
            try? fm.removeItem(at: marker)
            try? fm.removeItem(at: venv)  // a partial venv from an interrupted install is rebuilt
            let env = ProcessInfo.processInfo.environment.merging([
                "UV_CACHE_DIR": dir.appending(path: "uvcache").path,
                "UV_PYTHON_INSTALL_DIR": dir.appending(path: "pythons").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "UV_NO_CONFIG": "1",
            ]) { _, new in new }
            try await Self.run(uv, ["venv", "--python", spec.python, venv.path], env: env)
            try await Self.run(uv, ["pip", "install", "--python", python.path] + spec.requirements, env: env)
            try? fm.removeItem(at: dir.appending(path: "uvcache"))  // ~1.2 GB, only useful for reinstalls
            try want.write(to: marker, atomically: true, encoding: .utf8)
            Self.log.info("Installed \(want, privacy: .public) in \(Date().timeIntervalSince(started))s")
        }
        return Ready(dir: dir, python: python)
    }

    /// `uv` from PATH or the usual install spots, else the pinned standalone build (sha256-verified).
    private func locateUV(in dir: URL) async throws -> URL {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in path + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let c = URL(fileURLWithPath: d).appending(path: "uv")
            if fm.isExecutableFile(atPath: c.path) { return c }
        }
        let bin = dir.appending(path: "bin/uv")
        if fm.isExecutableFile(atPath: bin.path) { return bin }
        #if !arch(arm64)
        throw MFluxError.runtime("Automatic uv download is only available on Apple Silicon; install uv manually.")
        #endif
        let url = URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-aarch64-apple-darwin.tar.gz")!
        Self.log.info("Downloading uv \(Self.uvVersion)")
        let (tmp, response) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MFluxError.runtime("uv download failed.") }
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: tmp)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == Self.uvSHA256 else { throw MFluxError.runtime("uv download failed its checksum (got \(digest)).") }
        let extract = dir.appending(path: "uv-extract", directoryHint: .isDirectory)
        try? fm.removeItem(at: extract)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extract) }
        try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", tmp.path, "-C", extract.path], env: [:])
        try fm.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: bin)
        try fm.moveItem(at: extract.appending(path: "uv-aarch64-apple-darwin/uv"), to: bin)
        return bin
    }

    /// Runs a tool to completion; output is drained into the log and the tail is surfaced on failure.
    static func run(_ exe: URL, _ args: [String], env: [String: String]) async throws {
        try await runStreaming(exe, args, env: env, onLine: { _ in })
    }

    /// Like `run`, but calls `onLine` for each stdout/stderr line while the tool runs (split on `\n` and `\r`, since tqdm uses `\r`).
    /// Task cancellation terminates the process.
    ///
    /// The tool is killed once its memory (GPU memory included) has stayed above `memoryLimit` for `overFor`.
    /// macOS never kills it, and its own "available memory" figure doesn't count GPU memory: Wan's text encoder
    /// at 22 GB froze a 16 GB Mac twice while that figure stayed above 20%.
    static let overFor = Duration.seconds(2)

    static func runStreaming(_ exe: URL, _ args: [String], env: [String: String],
                             memoryLimit: Int = ProcessMemory.gpuWorkingSet,
                             onLine: @escaping @Sendable (String) -> Void) async throws {
        let p = Process()
        p.executableURL = exe; p.arguments = args
        if !env.isEmpty { p.environment = env }
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let tail = MFluxBuffer()
        let pending = LineSplitter(onLine)
        let reader = pipe.fileHandleForReading
        let starved = OSAllocatedUnfairLock<Int?>(initialState: nil)   // the tool's footprint when it was killed
        let watch = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        defer { watch.withLock { $0?.cancel() } }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Output is read only by the handler, so lines stay in order; resume once both end of file and exit arrive.
                let done = DispatchGroup()
                done.enter(); done.enter()
                reader.readabilityHandler = { h in
                    let d = h.availableData
                    // An empty read is end of file; left set, the handler would re-fire in a tight loop.
                    if d.isEmpty { h.readabilityHandler = nil; pending.flush(); done.leave() } else { tail.append(d); pending.feed(d) }
                }
                p.terminationHandler = { _ in done.leave() }
                do { try p.run() } catch { reader.readabilityHandler = nil; cont.resume(throwing: error); return }
                let pid = p.processIdentifier
                watch.withLock { $0 = Task.detached(priority: .high) {
                    var overSince: ContinuousClock.Instant?
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let used = ProcessMemory.footprint(tree: pid), used > memoryLimit else { overSince = nil; continue }
                        let since = overSince ?? .now
                        overSince = since
                        guard ContinuousClock.now - since >= overFor else { continue }
                        starved.withLock { $0 = used }
                        ProcessMemory.kill(tree: pid)
                        return
                    }
                } }
                done.notify(queue: .global()) { cont.resume(returning: p.terminationStatus) }
            }
        } onCancel: { if p.isRunning { p.terminate() } }
        let text = String(decoding: tail.data, as: UTF8.self)
        log.info("\(exe.lastPathComponent, privacy: .public) \(args.joined(separator: " "), privacy: .public): exit \(status)\n\(text, privacy: .public)")
        if let bytes = starved.withLock({ $0 }) {
            throw MFluxError.runtime(String(format: "Stopped: the generator needed %.1f GB, more than this Mac's GPU can hold (%.1f GB), "
                                            + "and would have frozen it. Try a smaller model.", Double(bytes) / 1e9, Double(memoryLimit) / 1e9))
        }
        guard status == 0 else {
            throw MFluxError.runtime("\(exe.lastPathComponent) \(args.first ?? "") failed (\(status)): \(String(text.suffix(600)))")
        }
    }
}

/// Splits a byte stream into lines on `\n` or `\r`, dropping empty ones.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    private let onLine: @Sendable (String) -> Void
    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }
    func feed(_ d: Data) {
        lock.lock()
        buf.append(d)
        var lines: [String] = []
        while let i = buf.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            if i > buf.startIndex { lines.append(String(decoding: buf[buf.startIndex..<i], as: UTF8.self)) }
            buf = buf.subdata(in: (i + 1)..<buf.endIndex)
        }
        lock.unlock()
        lines.forEach(onLine)
    }
    func flush() {
        lock.lock(); let rest = buf; buf = Data(); lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}
