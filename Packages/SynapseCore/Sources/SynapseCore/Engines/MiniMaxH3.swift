import CryptoKit
import Foundation

/// stable-diffusion.cpp's prebuilt macOS CLI (MIT), fetched on first use into `<store root>/runtimes/sd-cpp/<tag>`.
enum SDCpp {
    static let tag = "master-1106-532d2c1"
    static let asset = "sd-master-532d2c1-bin-Darwin-macOS-26.7.2-arm64.zip"
    static let sha256 = "8146d6ffc75f8ff8f64b62a80fffee8fb714ab65e368e202084135fa07cc6f36"

    static func ensureInstalled(storeRoot: URL) async throws -> URL {
        let dir = storeRoot.appending(path: "runtimes/sd-cpp/\(tag)", directoryHint: .isDirectory)
        let cli = dir.appending(path: "sd-cli")
        if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
        let url = URL(string: "https://github.com/leejet/stable-diffusion.cpp/releases/download/\(tag)/\(asset)")!
        let (zip, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MFluxError.runtime("stable-diffusion.cpp download failed.") }
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw MFluxError.runtime("stable-diffusion.cpp download failed its checksum (got \(digest)).") }
        let staging = dir.deletingLastPathComponent().appending(path: "\(tag).partial", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await PythonRuntime.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, staging.path], env: [:])
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: staging, to: dir)
        return cli
    }
}

/// MiniMax H3 (video with stereo sound) through stable-diffusion.cpp. Its parts come from four repos; which files
/// depends on the Mac, and the engine uses whichever set is in the model folder.
enum MiniMaxH3 {
    struct File { let repo: String; let path: String; let mb: Int }
    struct Parts { let transformer: File; let encoder: File; let vae: File; let audioVAE: File
        var all: [File] { [transformer, encoder, vae, audioVAE] }
        /// The int8 ConvRot 4B encoder crashes in Metal (KERN_PROTECTION_FAILURE in setBuffer) while encoding the
        /// prompt with sd.cpp master-1106; it runs on the CPU in seconds.
        var encoderOnCPU: Bool { encoder.path.contains("int8") }
    }

    static func handles(_ spec: ModelSpec) -> Bool { spec.variant == "MiniMaxAI/MiniMax-H3" }

    private static let audioVAE = File(repo: "Comfy-Org/MiniMax-H3", path: "vae/minimax_h3_audio_vae_fp32.safetensors", mb: 605)
    /// Under 64 GB: pruned 2-bit transformer, Qwen3-VL-4B encoder, distilled Sol decoder (14.4 GB).
    static let small = Parts(
        transformer: File(repo: "unsloth/MiniMax-H3-GGUF", path: "minimax_h3_fl2va_pruned-Q2_K.gguf", mb: 6724),
        encoder: File(repo: "PrunaAI/P-Image-OSS-Comfy", path: "text_encoders/p-h3-image_text_encoder_int8_convrot.safetensors", mb: 5121),
        vae: File(repo: "Comfy-Org/MiniMax-H3", path: "vae/minimax_h3_sol_vae_int8_convrot.safetensors", mb: 1988),
        audioVAE: audioVAE)
    /// 64 GB and up: the full 4-bit transformer with the 32B encoder H3 was trained with (43 GB).
    // shortcut: not yet run (this set was chosen from stable-diffusion.cpp's docs); verify on a Mac Studio.
    static let large = Parts(
        transformer: File(repo: "leejet/MiniMax-H3-GGUF", path: "minimax_h3_fl2va-Q4_K_M.gguf", mb: 18800),
        encoder: File(repo: "leejet/MiniMax-H3-GGUF", path: "qwen3vl_32b_minimax_h3-Q4_K_M.gguf", mb: 18200),
        vae: File(repo: "Comfy-Org/MiniMax-H3", path: "vae/minimax_h3_video_vae_fp16.safetensors", mb: 5200),
        audioVAE: audioVAE)

    static func files(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Parts {
        VideoEngines.lowMemory(physicalMemory) ? small : large
    }

    static func download(to dir: URL, token: String?, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let set = files(physicalMemory: physicalMemory).all
        let total = Double(set.reduce(0) { $0 + $1.mb })
        var done = 0.0
        for f in set {
            let before = done, share = Double(f.mb) / total
            _ = try await HFDownloader.download(repo: f.repo, to: dir, only: [f.path], token: token) { progress(before + $0 * share) }
            done += share
        }
        return dir
    }

    /// The set whose files are all in `folder` (a large Mac may have been given the small set, and vice versa).
    static func installed(in folder: URL) -> Parts? {
        [files(), small, large].first { $0.all.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0.path).path) } }
    }

    /// Distilled ("N-step") LoRAs replace the 20-step schedule.
    static func steps(loras: [URL]) -> Int {
        loras.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard let m = name.range(of: "([0-9]+)step", options: .regularExpression) else { return nil }
            return Int(name[m].dropLast(4))
        }.min() ?? 20
    }

    /// H3 weights a LoRA can patch, written with `_` for `.` (kohya files spell them that way).
    private static var patchable: Regex<(Substring, Substring?, Substring?, Substring?, Substring?, Substring?)> { /(token_refiner_)?blocks_\d+_(attn_(qkv|out)_proj|mlp_fc[12]|adaln_proj_linear)|(condition|video_patch|audio_patch)_proj|final_layer_(video_out|audio_out|adaln_proj_linear)/ }

    /// Tensors of a LoRA that patch no H3 weight. At run time sd.cpp skips those without a word, so a LoRA for
    /// another model would leave the clip unchanged. Covers the ComfyUI (`diffusion_model.blocks.0.attn.qkv_proj.lora_A.weight`)
    /// and kohya (`lora_unet_blocks_0_attn_qkv_proj.lora_down.weight`) layouts.
    static func unmatched(_ keys: [String]) -> [String] {
        keys.filter { key in
            guard key != "__metadata__" else { return false }
            var k = Substring(key)
            for prefix in ["lora.", "lora_unet_", "model.", "diffusion_model.", "transformer."] where k.hasPrefix(prefix) {
                k = k.dropFirst(prefix.count)
            }
            if let tail = k.firstRange(of: /[._](lora_(A|B|up|down|mid)|lora\.(up|down|mid)|alpha|scale|dora_scale|diff(_b)?)(\.|$)/) {
                k = k[..<tail.lowerBound]
            }
            return k.replacing(".", with: "_").wholeMatch(of: patchable) == nil
        }
    }

    /// Refuses a LoRA file that is not a safetensors LoRA for H3, before minutes of model loading.
    static func checkLoRA(_ file: URL) throws {
        let name = file.deletingPathExtension().lastPathComponent
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let size = try handle.read(upToCount: 8), size.count == 8,
              case let n = size.withUnsafeBytes({ UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }), n < 100_000_000,
              let header = try handle.read(upToCount: Int(n)),
              let keys = (try? JSONSerialization.jsonObject(with: header) as? [String: Any])?.keys else {
            throw MFluxError.runtime("The LoRA \(name) is not a readable safetensors file; delete it in Models and download it again.")
        }
        let all = Array(keys).filter { $0 != "__metadata__" }, bad = unmatched(all).sorted()
        guard bad.isEmpty, !all.isEmpty else {
            throw MFluxError.runtime("The LoRA \(name) does not fit MiniMax H3: \(bad.count) of its \(all.count) tensors match no H3 weight"
                + (bad.first.map { " (for example \($0))" } ?? "") + ". It was probably made for another model.")
        }
    }

    /// `loraDir` holds the clip's LoRAs as `lora0.safetensors`, `lora1.safetensors`, ... in `r.applied` order.
    static func arguments(_ r: VideoRequest, folder: URL, set: Parts, output: URL, startImage: URL?, loraDir: URL) -> [String] {
        // Sizes snap to 32 (VAE stride 16, patch 2); the CLI rounds the frame count to what H3 accepts.
        let w = max(32, r.width / 32 * 32), h = max(32, r.height / 32 * 32)
        var prompt = r.prompt
        var args = ["-M", "vid_gen",
                    "--diffusion-model", folder.appending(path: set.transformer.path).path,
                    "--llm", folder.appending(path: set.encoder.path).path,
                    "--vae", folder.appending(path: set.vae.path).path,
                    "--audio-vae", folder.appending(path: set.audioVAE.path).path,
                    "--cfg-scale", "1.0", "--steps", "\(steps(loras: r.applied.map(\.file)))",
                    "-W", "\(w)", "-H", "\(h)", "--fps", "\(r.fps)", "--video-frames", "\(r.frames)", "--rng", "cpu",
                    "--offload-to-cpu", "-o", output.path, "-v"]
        if !r.applied.isEmpty {
            // sd.cpp applies LoRAs named in the prompt from --lora-model-dir, at run time on quantized weights.
            args += ["--lora-model-dir", loraDir.path]
            for (i, lora) in r.applied.enumerated() { prompt += " <lora:lora\(i):\(String(format: "%g", lora.strength))>" }
        }
        if set.encoderOnCPU { args += ["--backend", "te=cpu"] }
        if VideoEngines.lowMemory() { args += ["--vae-tiling", "--temporal-tiling"] }
        if let seed = r.seed { args += ["-s", "\(seed % UInt64(Int64.max))"] }
        if let startImage { args += ["-i", startImage.path] }
        return args + ["-p", prompt]
    }
}

/// Overall progress from sd.cpp's log: sampling steps ("| 2/4 - 160.2s/it"), then decoder tiles, which on a 16 GB
/// Mac take longer than sampling (8 of 13 minutes for a 1.6 s clip).
final class H3Progress: @unchecked Sendable {
    static let sampling = 0.4
    private let lock = NSLock()
    private var decoding = false

    func feed(_ line: String) -> Double? {
        lock.withLock {
            if line.contains("sampling completed") { decoding = true; return Self.sampling }
            guard let m = line.range(of: "([0-9]+)/([0-9]+) - ", options: .regularExpression) else { return nil }
            let parts = line[m].dropLast(3).split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { return nil }
            let f = min(1, parts[0] / parts[1])
            return decoding ? Self.sampling + (1 - Self.sampling) * f : Self.sampling * f
        }
    }
}

actor H3VideoEngine: VideoEngine {
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func generate(_ r: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let set = MiniMaxH3.installed(in: folder) else {
            throw MFluxError.runtime("MiniMax H3 is missing some of its files; download it again in Models.")
        }
        let cli = try await SDCpp.ensureInstalled(storeRoot: try PythonRuntime.storeRoot(above: folder))
        let work = FileManager.default.temporaryDirectory.appending(path: "synapse-h3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var startImage: URL?
        if let image = r.inputImage {
            startImage = work.appending(path: "start.png")
            try image.write(to: startImage!)
        }
        // The LoRAs may sit in different folders; sd.cpp reads them from one.
        let loraDir = work.appending(path: "loras", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: loraDir, withIntermediateDirectories: true)
        for (i, lora) in r.applied.enumerated() {
            try MiniMaxH3.checkLoRA(lora.file)
            try FileManager.default.createSymbolicLink(at: loraDir.appending(path: "lora\(i).safetensors"), withDestinationURL: lora.file)
        }
        // An animated WebP keeps the soundtrack out of the container, as a WAV beside it (out.wav).
        let frames = work.appending(path: "out.webp")
        let tracker = H3Progress()
        try await PythonRuntime.runStreaming(cli, MiniMaxH3.arguments(r, folder: folder, set: set, output: frames, startImage: startImage,
                                                                                      loraDir: loraDir),
                                             env: [:]) { line in
            if let p = tracker.feed(line) { progress(p) }
        }
        guard FileManager.default.fileExists(atPath: frames.path) else {
            throw MFluxError.runtime("stable-diffusion.cpp finished without writing a video.")
        }
        let audio = work.appending(path: "out.wav")
        try await VideoFile.encode(frames: frames, fps: r.fps, audio: FileManager.default.fileExists(atPath: audio.path) ? audio : nil, to: output)
    }
}
