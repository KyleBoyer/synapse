import AVFoundation
import Foundation

public enum SoundError: Error, LocalizedError {
    case noModel, notDownloaded(String), unknownModel(String), unreadable
    public var errorDescription: String? {
        switch self {
        case .noModel: "No sound model is downloaded. Download Stable Audio 3 SFX or Music in Models."
        case .notDownloaded(let id): "Model '\(id)' is not downloaded."
        case .unknownModel(let id): "Model '\(id)' is not a sound model."
        case .unreadable: "The sound model wrote audio Synapse could not read."
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
    public nonisolated let encoder: AudioEncoder

    public init(store: ModelStore, models: ModelManager, encoder: AudioEncoder? = nil,
                engineFactory: @escaping EngineFactory = SoundEngines.real) {
        self.store = store; self.models = models; self.engineFactory = engineFactory
        self.encoder = encoder ?? AudioEncoder.bundled() ?? AudioEncoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"))
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
