import Foundation

/// Makes a downloaded mlx-vlm model fit a smaller Mac, once, in its own folder: MiniCPM-o's bf16 weights are
/// converted to 4-bit, and Qwen3-Omni's experts are repacked so they page from disk (mlx-vlm's expert offload).
/// Both use mlx-vlm's own tools. A marker file records the step, so it never runs twice.
public enum ModelPrep {
    public enum Step: String, Codable, Sendable {
        /// mlx_vlm.convert -q --q-bits 4; run on the CPU, where the GPU watchdog cannot kill long kernels.
        case quantize4
        /// mlx_vlm.moe_offload: experts in a per-expert store, an LRU of them resident.
        case offloadExperts
    }

    static let marker = "synapse-prep.json"
    /// Below this, these omni models are prepared after download.
    static let smallMacBytes: UInt64 = 32 << 30
    /// Qwen3-Omni's bf16 (70 GB) runs as downloaded only with this much memory.
    static let bf16QwenOmniBytes: UInt64 = 96 << 30

    /// The steps for this model on this Mac, in order; empty when it runs as downloaded.
    public static func steps(for spec: ModelSpec, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [Step] {
        switch spec.id {
        case "minicpm-o-4.5": return physicalMemory < smallMacBytes ? [.quantize4] : []
        case "qwen3-omni-30b":
            if physicalMemory >= bf16QwenOmniBytes { return [] }
            return physicalMemory < smallMacBytes ? [.quantize4, .offloadExperts] : [.quantize4]
        default: return []
        }
    }

    /// The first step, for callers that only ask whether there is work.
    public static func step(for spec: ModelSpec, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Step? {
        steps(for: spec, physicalMemory: physicalMemory).first
    }

    /// Whether the folder already has what a step produces (quantized elsewhere, or an earlier run without the marker).
    static func isDone(_ step: Step, _ folder: URL) -> Bool {
        switch step {
        case .quantize4:
            let config = (try? Data(contentsOf: folder.appending(path: "config.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return config?["quantization"] != nil
        case .offloadExperts:
            return FileManager.default.fileExists(atPath: folder.appending(path: "offload_index.json").path)
        }
    }

    public static func isPrepared(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: marker).path)
    }

    /// Runs this Mac's steps for `spec` unless the folder is already prepared. The folder is replaced in place.
    public static func prepareIfNeeded(_ spec: ModelSpec, folder: URL,
                                       physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) async throws {
        let steps = steps(for: spec, physicalMemory: physicalMemory)
        guard !steps.isEmpty, !isPrepared(folder) else { return }
        let rt = try await PythonRuntime.shared.ensureInstalled(.init(name: "mlx-vlm", requirements: ["mlx-vlm==\(MLXVLMServer.version)"]),
                                                                storeRoot: try PythonRuntime.storeRoot(above: folder))
        let env = ["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
                   "HF_HOME": rt.dir.appending(path: "hf").path]
        // Each step replaces the folder before the next starts, so the disk never holds more than two copies.
        for step in steps where !isDone(step, folder) { try await run(step, spec: spec, folder: folder, python: rt.python, env: env) }
        try JSONEncoder().encode(["steps": steps.map(\.rawValue)]).write(to: folder.appending(path: marker))
    }

    private static func run(_ step: Step, spec: ModelSpec, folder: URL, python: URL, env: [String: String]) async throws {
        let fm = FileManager.default
        let out = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".prep", directoryHint: .isDirectory)
        try? fm.removeItem(at: out)
        switch step {
        case .quantize4:
            let script = """
                import sys, runpy, mlx.core as mx
                mx.set_default_device(mx.cpu)
                sys.argv = ["mlx_vlm.convert", "--hf-path", sys.argv[1], "--mlx-path", sys.argv[2], "-q", "--q-bits", "4", "--trust-remote-code"]
                runpy.run_module("mlx_vlm.convert", run_name="__main__")
                """
            try await PythonRuntime.run(python, ["-c", script, folder.path, out.path], env: env)
        case .offloadExperts:
            try await PythonRuntime.run(python, ["-m", "mlx_vlm.moe_offload", "--build", folder.path, "--out", out.path], env: env)
        }
        guard fm.fileExists(atPath: out.appending(path: "config.json").path) else {
            throw MFluxError.runtime("Preparing \(spec.displayName) produced no model.")
        }
        // Swap in the prepared copy, then drop the original (that is the space and memory this step saves).
        let old = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".orig", directoryHint: .isDirectory)
        try? fm.removeItem(at: old)
        try fm.moveItem(at: folder, to: old)
        try fm.moveItem(at: out, to: folder)
        try? fm.removeItem(at: old)
    }
}
