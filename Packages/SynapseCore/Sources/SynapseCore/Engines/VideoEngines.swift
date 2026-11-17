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

    public static let real: @Sendable (ModelSpec, URL) async throws -> any VideoEngine = { _, folder in
        mock ? MockVideoEngine() : MLXVideoEngine(folder: folder)
    }

    /// LTX-2.3 publishes its transformer twice (18 shards, which its index names, and 8) plus files only the dev
    /// pipelines load, and no text encoder. LTX-2-distilled bundles the Gemma 3 12B encoder and tokenizer LTX-2.3
    /// uses, so those two folders are borrowed into the same model folder (the CLI looks for <folder>/text_encoder).
    static let ltxUnused = (1...8).map { "transformer/model-0000\($0)-of-00008.safetensors" } + [
        "ltx-2.3-22b-distilled-lora-384.safetensors", "ltx-2.3-temporal-upscaler-x2-1.0.safetensors",
        "ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors", "ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
    ]

    static func download(_ spec: ModelSpec, to dir: URL, token: String?,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // shortcut: progress splits evenly by repo, not by bytes; the two halves are about the same size.
        _ = try await HFDownloader.download(repo: spec.variant, to: dir, exclude: ltxUnused, token: token) { progress($0 * 0.5) }
        return try await HFDownloader.download(repo: "prince-canuma/LTX-2-distilled", to: dir, only: ["text_encoder/", "tokenizer/"],
                                               token: token) { progress(0.5 + $0 * 0.5) }
    }
}

/// Writes a solid-color clip with fake progress, so the API and the Video pane run without a 96 GB model.
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
        var args = ["-m", "mlx_video.models.ltx_2.generate", "--pipeline", "distilled", "--prompt", r.prompt,
                    "--width", "\(r.width)", "--height", "\(r.height)", "--num-frames", "\(r.frames)", "--fps", "\(r.fps)",
                    "--output-path", output.path, "--model-repo", folder.path, "--text-encoder-repo", folder.path, "--verbose"]
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
            "HF_HOME": rt.dir.appending(path: "hf").path,
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
