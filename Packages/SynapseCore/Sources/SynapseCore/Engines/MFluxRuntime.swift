import Foundation
import os

/// Managed Python runtime for the mflux sidecar: `<store root>/runtimes/mflux/{bin/uv, pythons, venv, uvcache}`.
/// Installation is idempotent (marker file written last) and serialized across engines.
actor MFluxRuntime {
    static let shared = MFluxRuntime()
    static let mfluxVersion = "0.24.0"
    static let log = Logger(subsystem: "synapse", category: "mflux-runtime")

    struct Ready: Sendable { let dir: URL; let python: URL; let script: URL; let env: [String: String] }

    func ensureInstalled(for folder: URL) async throws -> Ready {
        let root = try PythonRuntime.storeRoot(above: folder)
        let rt = try await PythonRuntime.shared.ensureInstalled(
            .init(name: "mflux", requirements: ["mflux==\(Self.mfluxVersion)"]), storeRoot: root)
        let dir = rt.dir
        let script = dir.appending(path: "synapse_imagegen.py")
        if (try? String(contentsOf: script, encoding: .utf8)) != MFluxSidecarScript.source {
            try MFluxSidecarScript.source.write(to: script, atomically: true, encoding: .utf8)
        }
        let cache = dir.appending(path: "hf", directoryHint: .isDirectory)
        let env = [
            "HF_HOME": cache.path, "HF_HUB_CACHE": cache.appending(path: "hub").path,
            "MFLUX_CACHE_DIR": dir.appending(path: "mflux-cache").path,
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
        ]
        return Ready(dir: dir, python: rt.python, script: script, env: env)
    }
}

enum MFluxError: Error, LocalizedError {
    case runtime(String), sidecar(String)
    var errorDescription: String? {
        switch self { case .runtime(let m): return "mflux runtime: \(m)"; case .sidecar(let m): return "mflux: \(m)" }
    }
}
