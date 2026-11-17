import Foundation

/// Text-to-speech for `POST /v1/audio/speech` and the Audio pane: maps OpenAI model names to the downloaded
/// TTS model and streams its PCM. TTS runs on Core ML (FluidAudio), not MLX, so no GPUGate is held.
public actor SpeechService {
    public typealias TTSFactory = @Sendable (ModelSpec) async throws -> any RealtimeTTS

    public static let pocketVoices = ["alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma"]
    public static let maxInputCharacters = 4096
    public static let preference = ["pocket-tts", "kokoro-82m"]

    public nonisolated let encoder: AudioEncoder
    /// Cloned voices and their consent recordings, under `<models>/voices/`.
    public nonisolated let voices: VoiceLibrary
    private let store: ModelStore
    private let decoder: AudioDecoder
    private let tts: TTSFactory

    init(store: ModelStore, encoder: AudioEncoder, decoder: AudioDecoder? = nil, tts: @escaping TTSFactory) {
        self.store = store; self.encoder = encoder; self.tts = tts
        self.decoder = decoder ?? AudioDecoder.bundled() ?? AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"))
        voices = VoiceLibrary(root: store.root.appending(path: "voices", directoryHint: .isDirectory))
    }

    public init(store: ModelStore, models: ModelManager, encoder: AudioEncoder? = nil) {
        self.init(store: store, encoder: encoder ?? AudioEncoder.bundled() ?? AudioEncoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false")),
                  tts: { spec in try await RealtimeServices.ttsLease(id: spec.id, store: store, models: models) })
    }

    static let cloningModel = "pocket-tts"

    /// Clones a voice from a sample (any format ffmpeg reads; the first 10 seconds are used, at least 1 is needed).
    public func createVoice(name: String, sample: URL, consentID: String?) async throws -> CustomVoice {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SpeechError.voice("name is required.") }
        if let consentID, await voices.consent(consentID) == nil { throw SpeechError.voice("Unknown consent '\(consentID)'.") }
        guard await store.downloaded.contains(Self.cloningModel), let spec = Catalog.spec(Self.cloningModel) else {
            throw SpeechError.voice("Voice cloning uses PocketTTS. Download it in Models.")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-voice/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try await decoder.decodeToWAV(.media(sample), into: dir, sampleRate: 24000)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
        let seconds = Double(max(bytes - 44, 0)) / 48_000
        guard seconds >= 1 else { throw SpeechError.voice("The sample is too short: use 5 to 10 seconds of one person speaking.") }
        guard let cloner = try await tts(spec) as? any VoiceCloning else { throw SpeechError.voice("This speech model cannot clone voices.") }
        return try await voices.add(name: name, consentID: consentID, seconds: min(seconds, 10), data: try await cloner.clone(wav: wav))
    }

    public func resolve(model: String?) async throws -> ModelSpec {
        let downloaded = await store.downloaded
        let aliases: Set<String> = ["", "tts-1", "tts-1-hd", "gpt-4o-mini-tts"]
        if let model, !aliases.contains(model) {
            guard let spec = Catalog.spec(model) else { throw ResolveError.unknownModel(model) }
            guard Self.preference.contains(spec.id) else { throw ResolveError.wrongKind(model) }
            guard downloaded.contains(spec.id) else { throw ResolveError.notDownloaded(model) }
            return spec
        }
        guard let id = Self.preference.first(where: downloaded.contains), let spec = Catalog.spec(id) else { throw SpeechError.noModel }
        return spec
    }

    public func synthesize(model: ModelSpec, text: String, voice: String?, speed: Double) async throws
        -> (sampleRate: Int, pcm: AsyncThrowingStream<[Float], Error>) {
        guard !text.isEmpty, text.count <= Self.maxInputCharacters else { throw SpeechError.badInput }
        let engine = try await tts(model)
        let source: AsyncThrowingStream<[Float], Error>
        if let voice, voice.hasPrefix("voice_") {
            guard let cloner = engine as? any VoiceCloning else {
                throw SpeechError.voice("Custom voices need PocketTTS; \(model.displayName) has fixed voices.")
            }
            guard let data = try await voices.voiceData(voice) else { throw SpeechError.voice("Unknown voice '\(voice)'.") }
            source = cloner.synthesize(text, voiceData: data)
        } else {
            source = engine.synthesize(text, voice: Self.voice(voice), speed: speed)
        }
        // The forwarding task holds `engine`, so a lease stays resident until the last frame is out.
        let pcm = AsyncThrowingStream<[Float], Error> { c in
            let task = Task {
                do {
                    for try await frame in source { c.yield(frame) }
                    c.finish()
                } catch { c.finish(throwing: error) }
                _ = engine
            }
            c.onTermination = { _ in task.cancel() }
        }
        return (engine.sampleRate, pcm)
    }

    /// A known PocketTTS voice, else nil (the engine default).
    public static func voice(_ requested: String?) -> String? {
        requested.flatMap { pocketVoices.contains($0) ? $0 : nil }
    }
}

public enum SpeechError: Error, LocalizedError {
    case noModel, badInput
    /// A custom voice problem the client can fix (missing name, unknown id, short sample, wrong model).
    case voice(String)
    public var errorDescription: String? {
        switch self {
        case .voice(let m): return m
        case .noModel: return "No speech model is downloaded. Download PocketTTS in Models."
        case .badInput: return "input must be 1 to \(SpeechService.maxInputCharacters) characters."
        }
    }
}
