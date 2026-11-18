import Foundation

/// Text-to-speech for `POST /v1/audio/speech` and the Audio pane: maps OpenAI model names to the downloaded
/// TTS model and streams its PCM, in a stock voice or one cloned from a clip. PocketTTS and Kokoro run on Core ML;
/// the mlx-audio models hold the GPU gate themselves.
public actor SpeechService {
    public typealias TTSFactory = @Sendable (ModelSpec) async throws -> any RealtimeTTS

    public static let pocketVoices = ["alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma"]
    public static let maxInputCharacters = 4096
    /// Default order for OpenAI model names; models with stock voices first, since a request may name no voice.
    public static let preference = ["pocket-tts", "kokoro-82m", "chatterbox-turbo", "voxcpm2", "qwen3-tts-1.7b"]

    /// What a speech model offers: stock voices (empty when it speaks only cloned voices), whether it clones, and
    /// whether cloning needs the clip's transcript.
    public struct VoiceSupport: Sendable, Equatable {
        public let stock: [String]
        public let clones: Bool
        public let needsTranscript: Bool
    }

    public static func support(_ modelID: String) -> VoiceSupport {
        switch modelID {
        case "pocket-tts": VoiceSupport(stock: pocketVoices, clones: true, needsTranscript: false)
        case "chatterbox-turbo", "voxcpm2": VoiceSupport(stock: ["default"], clones: true, needsTranscript: false)
        case "qwen3-tts-1.7b": VoiceSupport(stock: [], clones: true, needsTranscript: true)
        default: VoiceSupport(stock: ["default"], clones: false, needsTranscript: false)
        }
    }

    public nonisolated let encoder: AudioEncoder
    /// Cloned voices and their consent recordings, under `<models>/voices/`.
    public nonisolated let voices: VoiceLibrary
    private let store: ModelStore
    private let decoder: AudioDecoder
    private let tts: TTSFactory
    /// Speech to text for a voice's clip (the app's transcription queue); nil leaves transcripts empty.
    private let transcribe: (@Sendable (URL) async -> String?)?

    init(store: ModelStore, encoder: AudioEncoder, decoder: AudioDecoder? = nil,
         transcribe: (@Sendable (URL) async -> String?)? = nil, tts: @escaping TTSFactory) {
        self.store = store; self.encoder = encoder; self.tts = tts; self.transcribe = transcribe
        self.decoder = decoder ?? AudioDecoder.bundled() ?? AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"))
        voices = VoiceLibrary(root: store.root.appending(path: "voices", directoryHint: .isDirectory))
    }

    public init(store: ModelStore, models: ModelManager, encoder: AudioEncoder? = nil,
                transcribe: (@Sendable (URL) async -> String?)? = nil) {
        self.init(store: store, encoder: encoder ?? AudioEncoder.bundled() ?? AudioEncoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false")),
                  transcribe: transcribe,
                  tts: { spec in try await RealtimeServices.ttsLease(id: spec.id, store: store, models: models) })
    }

    /// Transcription through a job queue's direct path (not listed in Transcribe), for `transcribe:`.
    public static func transcriber(_ queue: JobQueue) -> @Sendable (URL) async -> String? {
        { url in try? await queue.transcribeNow(.media(url), modelID: nil, language: nil).text }
    }

    /// A voice from a sample (any format ffmpeg reads; the first 10 seconds are kept, at least 1 is needed). The clip is
    /// stored as is, so any model that clones can speak it; `transcript` defaults to a transcription of the clip.
    public func createVoice(name: String, sample: URL, transcript: String? = nil) async throws -> CustomVoice {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SpeechError.voice("name is required.") }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-voice/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try await decoder.decodeToWAV(.media(sample), into: dir, sampleRate: 24000)
        let all = PCM.floats(fromPCM16LE: try Data(contentsOf: wav).dropFirst(44))
        guard all.count >= 24000 else { throw SpeechError.voice("The sample is too short: use 5 to 10 seconds of one person speaking.") }
        let kept = Array(all.prefix(10 * 24000))
        let clip = dir.appending(path: "sample.wav")
        try PCM.wav16(kept, rate: 24000).write(to: clip)
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let heard = text == nil ? await transcribe?(clip)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
        return try await voices.add(name: name, sample: clip, seconds: Double(kept.count) / 24000, transcript: text ?? heard)
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
        let support = Self.support(model.id)
        var reference: VoiceReference?
        if let voice, voice.hasPrefix("voice_") {
            guard support.clones else {
                throw SpeechError.voice("\(model.displayName) has fixed voices; cloned voices work with PocketTTS, Chatterbox Turbo, VoxCPM2 and Qwen3-TTS.")
            }
            guard let ref = await voices.reference(voice) else { throw SpeechError.voice("Unknown voice '\(voice)'.") }
            if support.needsTranscript, ref.transcript == nil {
                throw SpeechError.voice("\(model.displayName) needs to know what the voice's clip says, and it has no transcript. Re-create the voice with a transcript, or with a transcription model downloaded.")
            }
            reference = ref
        } else if support.stock.isEmpty {
            throw SpeechError.voice("\(model.displayName) speaks only in a cloned voice: pass voice {\"id\": \"voice_…\"}.")
        }
        let engine = try await tts(model)
        let source: AsyncThrowingStream<[Float], Error>
        if let reference {
            guard let cloner = engine as? any ReferenceVoiceTTS else { throw SpeechError.voice("\(model.displayName) cannot clone voices.") }
            source = cloner.synthesize(text, reference: reference, speed: speed)
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

    public func isDownloaded(_ id: String) async -> Bool { await store.downloaded.contains(id) }

    /// Models that re-speak a recording in another voice.
    public static let converters: Set<String> = ["chatterbox-turbo"]

    /// `source` (any format ffmpeg reads) re-spoken in the cloned voice `voice` by a model that converts. The words
    /// and timing come from the recording; only the voice changes.
    public func convert(model: ModelSpec, source: URL, voice: String) async throws
        -> (sampleRate: Int, pcm: AsyncThrowingStream<[Float], Error>) {
        guard Self.converters.contains(model.id) else {
            throw SpeechError.voice("\(model.displayName) does not convert voices; use chatterbox-turbo.")
        }
        guard let ref = await voices.reference(voice) else { throw SpeechError.voice("Unknown voice '\(voice)'. Clone one first.") }
        let engine = try await tts(model)
        guard let converter = ((engine as? ClonedVoices)?.base ?? engine) as? any VoiceConverting else {
            throw SpeechError.voice("\(model.displayName) does not convert voices.")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "synapse-convert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The speech tokenizer reads 16 kHz.
        let wav: URL
        do { wav = try await decoder.decodeToWAV(.media(source), into: dir, sampleRate: 16000) } catch {
            try? FileManager.default.removeItem(at: dir)
            throw SpeechError.voice("The recording could not be read: \(error.localizedDescription)")
        }
        let source = converter.convert(source: wav, reference: ref)
        let pcm = AsyncThrowingStream<[Float], Error> { c in
            let task = Task {
                defer { try? FileManager.default.removeItem(at: dir) }
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

    /// A known PocketTTS voice or a cloned voice id, else nil (the engine default; OpenAI names like alloy land here).
    public static func voice(_ requested: String?) -> String? {
        requested.flatMap { pocketVoices.contains($0) || $0.hasPrefix("voice_") ? $0 : nil }
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
