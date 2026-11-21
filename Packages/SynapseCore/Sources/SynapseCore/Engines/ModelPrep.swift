import Foundation

/// Makes a downloaded mlx-vlm model fit a smaller Mac, once, in its own folder: MiniCPM-o's bf16 weights are
/// converted to 4-bit, and Qwen3-Omni's experts are repacked so they page from disk (mlx-vlm's expert offload).
/// Both use mlx-vlm's own tools. Inkling 2 Mini's GGUF is requantized with llama.cpp's llama-quantize. A marker file
/// records the step, so it never runs twice.
public enum ModelPrep {
    public enum Step: String, Codable, Sendable {
        /// mlx_vlm.convert -q --q-bits 4; run on the CPU, where the GPU watchdog cannot kill long kernels.
        case quantize4
        /// mlx_vlm.moe_offload: experts in a per-expert store, an LRU of them resident.
        case offloadExperts
        /// llama-quantize the GGUF weights (the catalog's first file) with the repo's imatrix, in place.
        case requantizeGGUF
    }

    /// Inkling 2 Mini under 32 GB: ggml-org's IQ4_NL (17.6 GB) leaves a 16 GB Mac swapping (0.4 tokens/s), and every
    /// smaller published quant keeps NVFP4 experts, which Metal cannot multiply (they run on the CPU at ~5 tokens/s).
    /// Gate/up experts at IQ2_S and down experts at IQ4_NL (their 1152 columns rule out 256-wide IQ3 blocks) give
    /// 11.1 GB, all on the GPU: 16 tokens/s on a 16 GB M4. Loop controller and conv weights stay F32.
    static let inklingMix = ["--tensor-type", "ffn_gate_up_exps=iq2_s", "--tensor-type", "ffn_down_exps=iq4_nl",
                             "--tensor-type", "(loop_|_conv\\.|_clip|rel_bias|ffn_gate_inp|res_query)=f32"]
    static let imatrix = "imatrix.gguf"

    static let marker = "synapse-prep.json"
    /// Below this, these omni models are prepared after download.
    static let smallMacBytes: UInt64 = 32 << 30
    /// Qwen3-Omni's bf16 (70 GB) runs as downloaded only with this much memory.
    static let bf16QwenOmniBytes: UInt64 = 96 << 30

    /// The steps for this model on this Mac, in order; empty when it runs as downloaded.
    public static func steps(for spec: ModelSpec, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [Step] {
        switch spec.id {
        case "inkling-2-mini": return physicalMemory < smallMacBytes ? [.requantizeGGUF] : []
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
        case .requantizeGGUF:
            return !FileManager.default.fileExists(atPath: folder.appending(path: imatrix).path)
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
        if steps == [.requantizeGGUF] {
            if !isDone(.requantizeGGUF, folder) { try await requantize(spec, folder) }
            try JSONEncoder().encode(["steps": steps.map(\.rawValue)]).write(to: folder.appending(path: marker))
            return
        }
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
        case .requantizeGGUF:
            return try await requantize(spec, folder)
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

    /// Writes the requantized weights beside the original, swaps them in, then drops the imatrix (which marks it done).
    private static func requantize(_ spec: ModelSpec, _ folder: URL) async throws {
        guard let exe = LlamaServer.binary("llama-quantize") else {
            throw EngineError.unsupported("llama-quantize is missing from this build (run scripts/build-llama.sh).")
        }
        guard let weights = spec.files?.first else { throw EngineError.unsupported("No GGUF weights file was chosen for this model.") }
        let src = folder.appending(path: weights), out = folder.appending(path: weights + ".prep")
        try? FileManager.default.removeItem(at: out)
        try await PythonRuntime.run(exe, ["--allow-requantize", "--imatrix", folder.appending(path: imatrix).path] + inklingMix
                                         + [src.path, out.path, "Q8_0"], env: [:])
        _ = try FileManager.default.replaceItemAt(src, withItemAt: out)
        try FileManager.default.removeItem(at: folder.appending(path: imatrix))
    }
}
