import AVFoundation
import Foundation

public enum SoundError: Error, LocalizedError {
    case noModel, notDownloaded(String), unknownModel(String), unreadable, noEditModel(AudioEditTask), needsPrompt(String)
    public var errorDescription: String? {
        switch self {
        case .noModel: "No sound model is downloaded. Download Stable Audio 3 SFX or Music in Models."
        case .notDownloaded(let id): "Model '\(id)' is not downloaded."
        case .unknownModel(let id): "Model '\(id)' is not a sound model."
        case .unreadable: "The sound model wrote audio Synapse could not read."
        case .noEditModel(.enhance): "No noise-removal model is downloaded. Download DeepFilterNet 3 in Models."
        case .noEditModel(.separate): "No separation model is downloaded. Download SAM-Audio small or DialogueSidon in Models."
        case .needsPrompt(let id): "\(id) separates the sound you describe; send prompt, for example \"speech\" or \"dog barking\"."
        }
    }
}

/// A generated clip: the WAV as written (stereo for Stable Audio) and a mono mix for playback and other encodings.
public struct SoundClip: Sendable {
    public let wav: Data
    public let mono: [Float]
    public let sampleRate: Int
    public var seconds: Double { Double(mono.count) / Double(sampleRate) }
}

/// What an audio-to-audio model does: clean up one recording, or split it into named tracks.
public enum AudioEditTask: String, Sendable { case enhance, separate }

/// One output of an audio edit: `audio` (enhanced), `target` / `residual` (SAM-Audio), `speaker_1` / `speaker_2`.
public struct AudioTrack: Sendable {
    public let name: String
    public let clip: SoundClip
}

/// Runs an audio-to-audio model on a WAV and writes each output track as `<name>.wav` into the output folder.
public typealias AudioEditRunner = @Sendable (_ spec: ModelSpec, _ folder: URL, _ input: URL, _ prompt: String?, _ out: URL) async throws -> Void

public protocol SoundEngine: Actor {
    func generate(prompt: String, seconds: Double, seed: UInt64?, to wav: URL) async throws
}

public enum SoundEngines {
    /// `SYNAPSE_MOCK_SOUND=1` swaps in a sine generator (tests, and Macs without the model).
    public static var mock: Bool { ProcessInfo.processInfo.environment["SYNAPSE_MOCK_SOUND"] == "1" }

    public static let real: @Sendable (ModelSpec, URL) async throws -> any SoundEngine = { _, folder in
        mock ? MockSoundEngine() : MLXAudioSoundEngine(folder: folder)
    }
}

public actor MockSoundEngine: SoundEngine {
    public init() {}
    public func generate(prompt: String, seconds: Double, seed: UInt64?, to wav: URL) async throws {
        let rate = 44100.0, n = Int(seconds * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 {
            for i in 0..<n { buffer.floatChannelData![c][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / Float(rate)) }
        }
        let file = try AVAudioFile(forWriting: wav, settings: format.settings)
        try file.write(from: buffer)
    }
}

/// Stable Audio 3 through mlx-audio's music CLI, one process per clip.
actor MLXAudioSoundEngine: SoundEngine {
    static let version = "0.6.6"
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func generate(prompt: String, seconds: Double, seed: UInt64?, to wav: URL) async throws {
        let rt = try await PythonRuntime.shared.ensureInstalled(.init(name: "mlx-audio", requirements: ["mlx-audio==\(Self.version)"]),
                                                                storeRoot: try PythonRuntime.storeRoot(above: folder))
        var args = ["-m", "mlx_audio.music.generate", "--model", folder.path, "--caption", prompt,
                    "--duration", String(format: "%.2f", seconds), "--output", wav.path]
        if let seed { args += ["--seed", "\(seed % UInt64(Int32.max))"] }
        try await PythonRuntime.run(rt.python, args, env: [
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
            "HF_HOME": rt.dir.appending(path: "hf").path,
        ])
    }
}

/// Text to sound effect or music. One clip at a time; the generator's memory is reserved only while it runs.
public actor SoundService {
    public typealias EngineFactory = @Sendable (ModelSpec, URL) async throws -> any SoundEngine
    /// Stable Audio 3 small: sample_size 5292032 at 44.1 kHz.
    public static let maxSeconds = 120.0
    private let store: ModelStore
    private let models: ModelManager
    private let engineFactory: EngineFactory
    private let editRunner: AudioEditRunner
    private let decoder: AudioDecoder?
    public nonisolated let encoder: AudioEncoder

    public init(store: ModelStore, models: ModelManager, encoder: AudioEncoder? = nil, decoder: AudioDecoder? = AudioDecoder.bundled(),
                engineFactory: @escaping EngineFactory = SoundEngines.real, editRunner: @escaping AudioEditRunner = MLXAudioEdit.run) {
        self.store = store; self.models = models; self.engineFactory = engineFactory
        self.editRunner = editRunner; self.decoder = decoder
        self.encoder = encoder ?? AudioEncoder.bundled() ?? AudioEncoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"))
    }

    // MARK: Audio to audio

    public static func editTask(_ spec: ModelSpec) -> AudioEditTask? {
        guard spec.isAudioEdit else { return nil }
        return ["deepfilternet-3", "nemotron-reuse"].contains(spec.id) ? .enhance : .separate
    }

    /// SAM-Audio separates whatever the prompt describes; the others need no prompt.
    public static func needsPrompt(_ spec: ModelSpec) -> Bool { spec.id.hasPrefix("sam-audio") }

    /// nil picks a downloaded model for the task: for separation, SAM-Audio when there is a prompt, DialogueSidon when not.
    public func resolveEdit(_ requested: String?, task: AudioEditTask, prompt: String?) async throws -> ModelSpec {
        let downloaded = await store.downloaded
        if let id = requested, !id.isEmpty {
            guard let spec = Catalog.spec(id), Self.editTask(spec) == task else { throw SoundError.unknownModel(id) }
            guard downloaded.contains(id) else { throw SoundError.notDownloaded(id) }
            return spec
        }
        let candidates = Catalog.all.filter { Self.editTask($0) == task && downloaded.contains($0.id) }
            .sorted { a, b in (prompt != nil) == Self.needsPrompt(a) && (prompt != nil) != Self.needsPrompt(b) }
        guard let spec = candidates.first(where: { prompt != nil || !Self.needsPrompt($0) }) ?? candidates.first else {
            throw SoundError.noEditModel(task)
        }
        return spec
    }

    /// Runs `spec` on a recording (any format the bundled ffmpeg reads) and returns its tracks, in name order.
    public func edit(model spec: ModelSpec, input: URL, prompt: String?) async throws -> [AudioTrack] {
        if Self.needsPrompt(spec), prompt?.isEmpty ?? true { throw SoundError.needsPrompt(spec.id) }
        guard let folder = await store.folder(for: spec.id) else { throw SoundError.notDownloaded(spec.id) }
        let work = FileManager.default.temporaryDirectory.appending(path: "synapse-audioedit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let out = work.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // 48 kHz mono WAV: every one of these models reads it (each resamples to its own rate) without a system ffmpeg.
        // shortcut: stereo input is mixed to mono; keep channels if music separation needs stereo output.
        let wav = try await decoder?.decodeToWAV(.media(input), into: work, sampleRate: 48000) ?? input
        let runner = editRunner
        try await models.reserve(spec.id, estimatedBytes: spec.estimatedBytes) {
            try await GPUGate.shared.run { try await runner(spec, folder, wav, prompt, out) }
        }
        let files = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw SoundError.unreadable }
        return try files.map { AudioTrack(name: $0.deletingPathExtension().lastPathComponent, clip: try Self.read($0)) }
    }

    /// The clip in `format`: the WAV as written, or a mono mix through the encoder.
    public func encoded(_ clip: SoundClip, as format: AudioFormat) async throws -> Data {
        // shortcut: non-WAV formats are mono mixes; pass stereo through AudioEncoder if clients want stereo MP3.
        if format == .wav { return clip.wav }
        let mono = clip.mono
        let pcm = AsyncThrowingStream<[Float], Error> { c in c.yield(mono); c.finish() }
        var out = Data()
        for try await chunk in encoder.encode(pcm, sampleRate: clip.sampleRate, as: format) { out.append(chunk) }
        return out
    }

    private func available(_ spec: ModelSpec) async -> Bool { SoundEngines.mock ? true : await store.folder(for: spec.id) != nil }

    /// nil picks the first downloaded sound model.
    public func resolve(_ requested: String?) async throws -> ModelSpec {
        if let id = requested, !id.isEmpty {
            guard let spec = Catalog.spec(id), spec.isAudioGen else { throw SoundError.unknownModel(id) }
            guard await available(spec) else { throw SoundError.notDownloaded(id) }
            return spec
        }
        for spec in Catalog.all where spec.isAudioGen { if await available(spec) { return spec } }
        throw SoundError.noModel
    }

    public func generate(model spec: ModelSpec, prompt: String, seconds: Double, seed: UInt64?) async throws -> SoundClip {
        let folder = await store.folder(for: spec.id) ?? FileManager.default.temporaryDirectory
        let engine = try await engineFactory(spec, folder)
        let wav = FileManager.default.temporaryDirectory.appending(path: "synapse-sound-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let run: @Sendable () async throws -> Void = {
            try await GPUGate.shared.run { try await engine.generate(prompt: prompt, seconds: seconds, seed: seed, to: wav) }
        }
        if SoundEngines.mock { try await run() } else {
            try await models.reserve(spec.id, estimatedBytes: spec.estimatedBytes, during: run)
        }
        return try Self.read(wav)
    }

    static func read(_ url: URL) throws -> SoundClip {
        let data = try Data(contentsOf: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SoundError.unreadable
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard let ch = buffer.floatChannelData, channels > 0 else { throw SoundError.unreadable }
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels { for i in 0..<n { mono[i] += ch[c][i] / Float(channels) } }
        return SoundClip(wav: data, mono: mono, sampleRate: Int(file.processingFormat.sampleRate))
    }
}

/// mlx-audio's speech-to-speech models, one process per recording (model load is seconds for these sizes).
public enum MLXAudioEdit {
    public static let run: AudioEditRunner = { _, folder, input, prompt, out in
        let rt = try await PythonRuntime.shared.ensureInstalled(.init(name: "mlx-audio", requirements: ["mlx-audio==\(MLXAudioSoundEngine.version)"]),
                                                                storeRoot: try PythonRuntime.storeRoot(above: folder))
        // Not offline: SAM-Audio's checkpoint leaves out its T5 text encoder, which mlx-audio fetches (t5-base, into the
        // runtime's own cache) on first use.
        try await PythonRuntime.run(rt.python, ["-c", script, folder.path, input.path, out.path, prompt ?? ""], env: [
            "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false", "HF_HOME": rt.dir.appending(path: "hf").path,
        ])
    }

    /// argv: model folder, input WAV, output folder, prompt (may be empty). Writes `<track>.wav` per output.
    static let script = #"""
import sys
from pathlib import Path
import numpy as np
from mlx_audio import audio_io
from mlx_audio.sts.utils import load_model

folder, source, out, prompt = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), sys.argv[4]
model = load_model(folder)
if not callable(getattr(model, "generate", None)):
    # SAM-Audio: separate() takes a description of the sound to pull out.
    r = model.separate(audios=[source], descriptions=[prompt])
    rate, tracks = model.sample_rate, {"target": r.target[0], "residual": r.residual[0]}
else:
    r = model.generate(source)
    rate, tracks = r.sample_rate, dict(getattr(r, "audios", None) or {})
    if r.audio is not None and not tracks:
        tracks["audio"] = r.audio
for name, a in tracks.items():
    a = np.array(a, dtype=np.float32)
    a = a.reshape(-1) if a.ndim == 1 or min(a.shape) == 1 else (a.T if a.shape[0] < a.shape[1] else a)
    audio_io.write(str(out / f"{name}.wav"), a, int(rate))
"""#
}
