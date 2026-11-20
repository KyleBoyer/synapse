import Foundation

public struct VideoRequest: Sendable, Equatable {
    public var prompt: String
    public var width: Int
    public var height: Int
    public var frames: Int
    public var fps: Int
    public var seed: UInt64?
    /// Optional start image (PNG/JPEG bytes) for image-to-video.
    public var inputImage: Data?

    public init(prompt: String, width: Int, height: Int, frames: Int, fps: Int = 24, seed: UInt64? = nil, inputImage: Data? = nil) {
        self.prompt = prompt; self.width = width; self.height = height; self.frames = frames; self.fps = fps
        self.seed = seed; self.inputImage = inputImage
    }
}

/// Generates one clip into `output` (MP4), reporting progress from 0 to 1.
public protocol VideoEngine: Actor {
    func generate(_ r: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

public enum VideoEngines {
    /// `SYNAPSE_MOCK_VIDEO=1` swaps in the mock engine (tests, and Macs without the RAM for LTX).
    public static var mock: Bool { ProcessInfo.processInfo.environment["SYNAPSE_MOCK_VIDEO"] == "1" }

    public static let real: @Sendable (ModelSpec, URL) async throws -> any VideoEngine = { spec, folder in
        if mock { return MockVideoEngine() }
        return Wan.handles(spec) ? WanVideoEngine(folder: folder) as any VideoEngine : MLXVideoEngine(folder: folder)
    }

    /// LTX-2.3 publishes its transformer twice (18 shards, which its index names, and 8) plus files only the dev
    /// pipelines load, and no text encoder. LTX-2-distilled bundles the Gemma 3 12B encoder and tokenizer LTX-2.3
    /// uses, so those two folders are borrowed into the same model folder (the CLI looks for <folder>/text_encoder).
    static let ltxUnused = (1...8).map { "transformer/model-0000\($0)-of-00008.safetensors" } + [
        "ltx-2.3-22b-distilled-lora-384.safetensors", "ltx-2.3-temporal-upscaler-x2-1.0.safetensors",
        "ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors", "ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
    ]

    /// Below this, LTX runs in low-memory mode: a 4-bit Gemma text encoder and the transformer quantized as it loads.
    /// Above it, the fp32 encoder (~48 GB) and bf16 transformer (~44 GB) load one after the other.
    static let fullPrecisionBytes: UInt64 = 64 << 30
    static let smallEncoderRepo = "mlx-community/gemma-3-12b-it-4bit"
    static func lowMemory(_ physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory < fullPrecisionBytes
    }
    /// Transformer bits in low-memory mode. 4-bit is ~12.4 GB of LTX-2.3's 22B parameters, too close to a 16 GB
    /// Mac's GPU working set (~11.8 GiB); 3-bit is ~9.6 GB.
    static func lowMemoryBits(_ physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        physicalMemory < 24 << 30 ? 3 : 4
    }

    static func download(_ spec: ModelSpec, to dir: URL, root: URL, token: String?,
                         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if Wan.handles(spec) { return try await Wan.download(spec, to: dir, token: token, progress: progress) }
        // shortcut: progress splits evenly by repo, not by bytes; the two halves are about the same size.
        _ = try await HFDownloader.download(repo: spec.variant, to: dir, exclude: ltxUnused, token: token) { progress($0 * 0.5) }
        guard lowMemory(physicalMemory) else {
            return try await HFDownloader.download(repo: "prince-canuma/LTX-2-distilled", to: dir, only: ["text_encoder/", "tokenizer/"],
                                                   token: token) { progress(0.5 + $0 * 0.5) }
        }
        // Low-memory Macs never load the fp32 encoder: fetch the 8 GB 4-bit Gemma instead, plus LTX-2's tokenizer.
        _ = try await HFDownloader.download(repo: "prince-canuma/LTX-2-distilled", to: dir, only: ["tokenizer/"], token: token) { _ in }
        _ = try await HFDownloader.download(repo: smallEncoderRepo, to: root.appending(path: "mlx/\(smallEncoderRepo)"),
                                            token: token) { progress(0.5 + $0 * 0.5) }
        return dir
    }
}

/// Writes a solid-color clip with fake progress, so tests and the Video pane run without the model.
public actor MockVideoEngine: VideoEngine {
    public init() {}
    public func generate(_ r: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        for step in 1...8 {
            try await Task.sleep(for: .milliseconds(50))
            progress(Double(step) / 8)
        }
        try await VideoFile.writeSolidColor(to: output, width: r.width, height: r.height, frames: r.frames, fps: r.fps)
    }
}

/// LTX-2.3 through mlx-video's CLI, one process per clip (the model loads per run; nothing stays resident).
actor MLXVideoEngine: VideoEngine {
    static let commit = "87db56a51758fefb748a359b90a5283bb8ba4837"
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func generate(_ r: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let rt: PythonRuntime.Ready
        do {
            rt = try await PythonRuntime.shared.ensureInstalled(
                .init(name: "mlx-video", requirements: ["mlx-video @ git+https://github.com/Blaizzy/mlx-video.git@\(Self.commit)"]),
                storeRoot: try PythonRuntime.storeRoot(above: folder))
        } catch {
            let hint = "\(error)".lowercased().contains("git") ? " Video generation needs git (install Xcode Command Line Tools)." : ""
            throw MFluxError.runtime("Could not install mlx-video.\(hint) \(error.localizedDescription)")
        }
        let low = VideoEngines.lowMemory()
        let encoder = low ? try PythonRuntime.storeRoot(above: folder).appending(path: "mlx/\(VideoEngines.smallEncoderRepo)") : folder
        if low, !FileManager.default.fileExists(atPath: encoder.appending(path: "config.json").path) {
            throw MFluxError.runtime("LTX-2.3 needs its 4-bit text encoder on this Mac; download the model again in Models.")
        }
        // Low-memory Macs run the generator through a wrapper that quantizes the transformer while it loads.
        var args = (low ? ["-c", LTXLowMemoryScript.source] : ["-m", "mlx_video.models.ltx_2.generate"]) + [
            "--pipeline", "distilled", "--prompt", r.prompt,
            "--width", "\(r.width)", "--height", "\(r.height)", "--num-frames", "\(r.frames)", "--fps", "\(r.fps)",
            "--output-path", output.path, "--model-repo", folder.path, "--text-encoder-repo", encoder.path, "--verbose"]
        if let seed = r.seed { args += ["--seed", "\(seed)"] }
        var startImage: URL?
        if let image = r.inputImage {
            let f = FileManager.default.temporaryDirectory.appending(path: "synapse-start-\(UUID().uuidString).png")
            try image.write(to: f)
            startImage = f
            args += ["--image", f.path]
        }
        defer { if let startImage { try? FileManager.default.removeItem(at: startImage) } }
        let env = [
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
            "HF_HOME": rt.dir.appending(path: "hf").path, "SYNAPSE_LTX_BITS": "\(VideoEngines.lowMemoryBits())",
            // Rich draws its progress bar only on a terminal; these make it print "Denoising ... 42%" lines into the pipe.
            "FORCE_COLOR": "1", "TTY_INTERACTIVE": "1", "COLUMNS": "120",
        ]
        let tracker = LTXProgress()
        try await PythonRuntime.runStreaming(rt.python, args, env: env) { line in
            if let p = tracker.feed(line) { progress(p) }
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MFluxError.runtime("mlx-video finished without writing \(output.lastPathComponent).")
        }
    }
}

/// Overall progress from mlx-video's Rich output. The distilled pipeline denoises twice (half resolution, then
/// full after upscaling); each bar runs 0-100%, so a bar that restarts lower means the next stage.
final class LTXProgress: @unchecked Sendable {
    static let stages = 2.0
    private let lock = NSLock()
    private var stage = 0
    private var last = -1

    /// Returns 0...1 for a "Denoising ... NN%" line, nil for anything else.
    func feed(_ line: String) -> Double? {
        let plain = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        guard plain.contains("Denoising"),
              let m = plain.range(of: "([0-9]{1,3})%", options: .regularExpression),
              let pct = Int(plain[m].dropLast()) else { return nil }
        return lock.withLock {
            if pct < last { stage += 1 }
            last = pct
            return min(1, (Double(stage) + Double(pct) / 100) / Self.stages)
        }
    }
}

/// Wan 2.2 TI2V-5B (Apache-2.0) through mlx-video's Wan pipeline: text or a start image to video, 24 fps. The
/// pipeline loads its tokenizer by Hub name at run time, so the tokenizer files are fetched beside the model and a
/// small wrapper points the lookup there (the run stays offline).
enum Wan {
    static let tokenizerRepo = "google/umt5-xxl", tokenizerFolder = "umt5-tokenizer"
    static func handles(_ spec: ModelSpec) -> Bool { spec.variant.contains("Wan2.2") }

    static func download(_ spec: ModelSpec, to dir: URL, token: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = try await HFDownloader.download(repo: spec.variant, to: dir, token: token, progress: progress)
        _ = try await HFDownloader.download(repo: tokenizerRepo, to: folder.appending(path: tokenizerFolder, directoryHint: .isDirectory),
                                            only: ["spiece.model", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"],
                                            token: token) { _ in }
        return folder
    }

    static let script = """
    import os, sys, runpy, transformers
    _load = transformers.AutoTokenizer.from_pretrained
    transformers.AutoTokenizer.from_pretrained = lambda name, *a, **k: _load(os.environ["SYNAPSE_WAN_TOKENIZER"] if name == "\(tokenizerRepo)" else name, *a, **k)
    sys.argv = ["wan"] + sys.argv[1:]
    runpy.run_module("mlx_video.models.wan_2.generate", run_name="__main__")
    """
}

actor WanVideoEngine: VideoEngine {
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func generate(_ r: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let rt = try await PythonRuntime.shared.ensureInstalled(
            .init(name: "mlx-video", requirements: ["mlx-video @ git+https://github.com/Blaizzy/mlx-video.git@\(MLXVideoEngine.commit)"]),
            storeRoot: try PythonRuntime.storeRoot(above: folder))
        // Sizes are multiples of 32 (VAE stride 16, patch 2) and frame counts 4n+1.
        let w = max(32, r.width / 32 * 32), h = max(32, r.height / 32 * 32), frames = max(5, (r.frames - 1) / 4 * 4 + 1)
        var args = ["-c", Wan.script, "--model-dir", folder.path, "--prompt", r.prompt, "--width", "\(w)", "--height", "\(h)",
                    "--num-frames", "\(frames)", "--output-path", output.path]
        // The auto tiling decodes every frame at once and runs out of GPU memory on 16 GB (after the whole denoise);
        // small spatial and 32-frame tiles decode an 832x480, 49-frame clip in ~4.5 min there.
        if VideoEngines.lowMemory() { args += ["--tiling", "aggressive"] }
        if let seed = r.seed { args += ["--seed", "\(seed % UInt64(Int32.max))"] }
        var startImage: URL?
        if let image = r.inputImage {
            let f = FileManager.default.temporaryDirectory.appending(path: "synapse-start-\(UUID().uuidString).png")
            try image.write(to: f)
            startImage = f
            args += ["--image", f.path]
        }
        defer { if let startImage { try? FileManager.default.removeItem(at: startImage) } }
        let env = [
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
            "HF_HOME": rt.dir.appending(path: "hf").path,
            "SYNAPSE_WAN_TOKENIZER": folder.appending(path: Wan.tokenizerFolder).path,
        ]
        try await PythonRuntime.runStreaming(rt.python, args, env: env) { line in
            // tqdm: "Diffusion:  53%|█████▎    | 16/30 [...]"
            guard line.contains("Diffusion"), let m = line.range(of: "([0-9]{1,3})%", options: .regularExpression),
                  let pct = Double(line[m].dropLast()) else { return }
            progress(pct / 100)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MFluxError.runtime("mlx-video finished without writing \(output.lastPathComponent).")
        }
    }
}
