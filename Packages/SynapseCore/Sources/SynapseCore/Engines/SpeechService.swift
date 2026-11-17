import Foundation

/// Text-to-speech for `POST /v1/audio/speech` and the Audio pane: maps OpenAI model names to the downloaded
/// TTS model and streams its PCM. TTS runs on Core ML (FluidAudio), not MLX, so no GPUGate is held.
public actor SpeechService {
    public typealias TTSFactory = @Sendable (ModelSpec) async throws -> any RealtimeTTS

    public static let pocketVoices = ["alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma"]
    public static let maxInputCharacters = 4096
    public static let preference = ["pocket-tts", "kokoro-82m"]

    public nonisolated let encoder: AudioEncoder
    private let store: ModelStore
    private let tts: TTSFactory

    init(store: ModelStore, encoder: AudioEncoder, tts: @escaping TTSFactory) {
        self.store = store; self.encoder = encoder; self.tts = tts
    }

    public init(store: ModelStore, models: ModelManager, encoder: AudioEncoder? = nil) {
        self.init(store: store, encoder: encoder ?? AudioEncoder.bundled() ?? AudioEncoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false")),
                  tts: { spec in try await RealtimeServices.ttsLease(id: spec.id, store: store, models: models) })
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
        let source = engine.synthesize(text, voice: Self.voice(voice), speed: speed)
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
    public var errorDescription: String? {
        switch self {
        case .noModel: return "No speech model is downloaded. Download PocketTTS in Models."
        case .badInput: return "input must be 1 to \(SpeechService.maxInputCharacters) characters."
        }
    }
}
