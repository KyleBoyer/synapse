import CryptoKit
import Foundation
import os

/// Managed Python runtime for the mflux sidecar: `<store root>/runtimes/mflux/{bin/uv, pythons, venv, uvcache}`.
/// Installation is idempotent (marker file written last) and serialized across engines.
actor MFluxRuntime {
    static let shared = MFluxRuntime()
    static let mfluxVersion = "0.24.0"
    static let uvVersion = "0.8.22"
    static let uvSHA256 = "3f61099e261e449527141dbf125629fab33ad696468c8c90cebbac40185a306c"
    static let log = Logger(subsystem: "synapse", category: "mflux-runtime")

    struct Ready: Sendable { let dir: URL; let python: URL; let script: URL; let env: [String: String] }

    /// Walks up from the model folder to the ModelStore root (the directory holding manifest.json).
    static func runtimeDir(for folder: URL) throws -> URL {
        var dir = folder.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "manifest.json").path) {
                return dir.appending(path: "runtimes/mflux", directoryHint: .isDirectory)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw MFluxError.runtime("Could not locate the model store root above \(folder.path).")
    }

    func ensureInstalled(for folder: URL) async throws -> Ready {
        let dir = try Self.runtimeDir(for: folder)
        let fm = FileManager.default
        let venv = dir.appending(path: "venv", directoryHint: .isDirectory)
        let python = venv.appending(path: "bin/python")
        let marker = dir.appending(path: "installed.txt")
        let want = "mflux==\(Self.mfluxVersion)"
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var env: [String: String] = [
            "UV_CACHE_DIR": dir.appending(path: "uvcache").path,
            "UV_PYTHON_INSTALL_DIR": dir.appending(path: "pythons").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_NO_CONFIG": "1",
        ]
        let installed = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == want
        if !(installed && fm.isExecutableFile(atPath: python.path)) {
            let started = Date()
            Self.log.info("Installing \(want) into \(dir.path)")
            let uv = try await locateUV(in: dir)
            try? fm.removeItem(at: marker)
            try? fm.removeItem(at: venv)  // a partial venv from an interrupted install is rebuilt
            let base = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            try await Self.run(uv, ["venv", "--python", "3.12", venv.path], env: base)
            try await Self.run(uv, ["pip", "install", "--python", python.path, want], env: base)
            try? fm.removeItem(at: dir.appending(path: "uvcache"))  // ~1.2 GB, only useful for reinstalls
            try want.write(to: marker, atomically: true, encoding: .utf8)
            Self.log.info("Installed \(want) in \(Date().timeIntervalSince(started))s")
        }
        let script = dir.appending(path: "synapse_imagegen.py")
        if (try? String(contentsOf: script, encoding: .utf8)) != MFluxSidecarScript.source {
            try MFluxSidecarScript.source.write(to: script, atomically: true, encoding: .utf8)
        }
        let cache = dir.appending(path: "hf", directoryHint: .isDirectory)
        env = [
            "HF_HOME": cache.path, "HF_HUB_CACHE": cache.appending(path: "hub").path,
            "MFLUX_CACHE_DIR": dir.appending(path: "mflux-cache").path,
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
        ]
        return Ready(dir: dir, python: python, script: script, env: env)
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
        let p = Process()
        p.executableURL = exe; p.arguments = args
        if !env.isEmpty { p.environment = env }
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let tail = MFluxBuffer()
        let reader = pipe.fileHandleForReading
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                reader.readabilityHandler = { tail.append($0.availableData) }
                p.terminationHandler = { p in
                    reader.readabilityHandler = nil
                    tail.append((try? reader.readToEnd()) ?? Data())
                    cont.resume(returning: p.terminationStatus)
                }
                do { try p.run() } catch { reader.readabilityHandler = nil; cont.resume(throwing: error) }
            }
        } onCancel: { if p.isRunning { p.terminate() } }
        let text = String(decoding: tail.data, as: UTF8.self)
        log.info("\(exe.lastPathComponent) \(args.joined(separator: " "), privacy: .public): exit \(status)\n\(text, privacy: .public)")
        guard status == 0 else {
            throw MFluxError.runtime("\(exe.lastPathComponent) \(args.first ?? "") failed (\(status)): \(String(text.suffix(600)))")
        }
    }
}

enum MFluxError: Error, LocalizedError {
    case runtime(String), sidecar(String)
    var errorDescription: String? {
        switch self { case .runtime(let m): return "mflux runtime: \(m)"; case .sidecar(let m): return "mflux: \(m)" }
    }
}
