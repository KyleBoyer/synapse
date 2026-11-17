import Foundation

public enum EngineKind: String, Codable, Sendable {
    case whisper, parakeet
    /// MLX chat/vision language models (Qwen3.5); `ModelSpec.variant` is the Hugging Face repo id.
    case mlx
    /// Image models. Native Swift/MLX: FLUX.2 and Z-Image. Python mflux sidecar: Qwen-Image.
    case flux2, zimage, mflux
    /// Realtime building blocks run by FluidAudio: streaming ASR, VAD, streaming TTS.
    case speech
    /// Full-duplex speech-to-speech and speech translation models (vendored speech-swift).
    case duplex
    /// Text embedding models (MLXEmbedders) and rerankers (MLXRerankers); `variant` is the Hugging Face repo id.
    case embedding, reranker
    /// Python helper processes: video generation (mlx-video) and music/sound generation (mlx-audio).
    case videogen, audiogen
    /// Chat models served by a managed mlx-vlm server (omni models with audio/video input).
    case mlxvlm
    /// GGUF chat models served by a bundled llama.cpp server; `ModelSpec.files` names the weights (and projector).
    case gguf
    /// Text-to-speech models that clone voices, run by a managed mlx-audio sidecar; `variant` is the Hugging Face repo id.
    case mlxspeech
}

public struct ModelSpec: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let engine: EngineKind
    public let displayName: String
    /// WhisperKit variant string, or "v3"/"v2" for Parakeet.
    public let variant: String
    public let approxMB: Int
    /// nil = every Whisper language; otherwise ISO-639-1 codes.
    public let languages: Set<String>?
    public let canTranslate: Bool
    public let canDetectLanguage: Bool
    public let canEditImages: Bool
    /// Physical memory below which the model is expected to page heavily (shown as a warning).
    public let recommendedRAMGB: Int?
    /// The files to fetch when a repo holds alternatives (GGUF quantizations): weights first, then any vision projector.
    public let files: [String]?

    public init(id: String, engine: EngineKind, displayName: String, variant: String, approxMB: Int,
                languages: Set<String>?, canTranslate: Bool, canDetectLanguage: Bool,
                canEditImages: Bool = false, recommendedRAMGB: Int? = nil, files: [String]? = nil) {
        self.id = id; self.engine = engine; self.displayName = displayName; self.variant = variant
        self.approxMB = approxMB; self.languages = languages
        self.canTranslate = canTranslate; self.canDetectLanguage = canDetectLanguage
        self.canEditImages = canEditImages; self.recommendedRAMGB = recommendedRAMGB; self.files = files
    }

    public var isChat: Bool { engine == .mlx || engine == .mlxvlm || engine == .gguf }
    public var isEmbedding: Bool { engine == .embedding }
    public var isReranker: Bool { engine == .reranker }
    public var isVideoGen: Bool { engine == .videogen }
    public var isAudioGen: Bool { engine == .audiogen }
    /// Models behind `POST /v1/audio/speech`.
    public var isTTS: Bool { SpeechService.preference.contains(id) }
    public var isImage: Bool { engine == .flux2 || engine == .zimage || engine == .mflux }
    public var isTranscription: Bool { engine == .whisper || engine == .parakeet }
    public var isRealtime: Bool { engine == .speech || engine == .duplex }

    /// Resident-size estimate for memory accounting (quantized weights load at about their on-disk size).
    public var estimatedBytes: Int { approxMB * 1_048_576 }

    public func supports(language: String?) -> Bool {
        guard let language, let languages else { return true }
        return languages.contains(language)
    }
}

public enum ModelState: Sendable, Equatable {
    case notDownloaded, downloading(Double), ready(URL), failed(String)
}

public struct Word: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct Segment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]
    /// Speaker label ("A", "B", ...) when the transcript was diarized.
    public var speaker: String?
    public init(start: Double, end: Double, text: String, words: [Word] = [], speaker: String? = nil) {
        self.start = start; self.end = end; self.text = text; self.words = words; self.speaker = speaker
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    /// ISO-639-1 when known.
    public var language: String?
    public var duration: Double
    public var segments: [Segment]
    public init(language: String?, duration: Double, segments: [Segment]) {
        self.language = language; self.duration = duration; self.segments = segments
    }
    public var text: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum TaskKind: String, Codable, Sendable, CaseIterable { case transcribe, translate }

public enum OutputFormat: String, Codable, Sendable, CaseIterable {
    // "text" is OpenAI's name for txt; both render identically.
    case srt, vtt, txt, tsv, json, verboseJSON = "verbose_json", text
    /// OpenAI's speaker-labelled transcript (`gpt-4o-transcribe-diarize`); requesting it turns diarization on.
    case diarizedJSON = "diarized_json"
}

public enum AudioInput: Sendable, Equatable {
    /// Any container ffmpeg can read.
    case media(URL)
    /// Headerless s16le 16 kHz mono (what Bazarr sends with encode=false).
    case pcm16le(URL)

    public var url: URL {
        switch self { case .media(let u), .pcm16le(let u): return u }
    }
}

public enum JobOrigin: String, Codable, Sendable { case gui, api, watcher }

public struct JobRequest: Sendable, Equatable {
    public var input: AudioInput
    /// nil = the resolver's default.
    public var modelID: String?
    /// nil = auto.
    public var language: String?
    public var task: TaskKind
    /// Source media URL; when set, an .srt is written next to it.
    public var writeSidecarNextTo: URL?
    public var force: Bool
    public var origin: JobOrigin
    /// Label who speaks when (needs the speaker-diarizer model).
    public var diarize: Bool

    public init(input: AudioInput, modelID: String? = nil, language: String? = nil, task: TaskKind = .transcribe,
                writeSidecarNextTo: URL? = nil, force: Bool = false, origin: JobOrigin, diarize: Bool = false) {
        self.input = input; self.modelID = modelID; self.language = language; self.task = task
        self.writeSidecarNextTo = writeSidecarNextTo; self.force = force; self.origin = origin; self.diarize = diarize
    }
}

public enum JobStatus: Sendable, Equatable {
    case queued, preparingModel, decoding, transcribing(Double?), diarizing, done, failed(String), cancelled, skipped(String)

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled, .skipped: return true
        default: return false
        }
    }

    /// Wire name used by the jobs API.
    public var apiName: String {
        switch self {
        case .queued: return "queued"
        case .preparingModel: return "preparing_model"
        case .decoding: return "decoding"
        case .transcribing: return "transcribing"
        case .diarizing: return "diarizing"
        case .done: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .skipped: return "skipped"
        }
    }
}

public struct JobSnapshot: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let request: JobRequest
    public var status: JobStatus
    /// The model actually used.
    public var modelID: String?
    public var transcript: Transcript?
    public var outputURL: URL?
    public let createdAt: Date

    public init(id: UUID = UUID(), request: JobRequest, status: JobStatus = .queued, modelID: String? = nil,
                transcript: Transcript? = nil, outputURL: URL? = nil, createdAt: Date = Date()) {
        self.id = id; self.request = request; self.status = status; self.modelID = modelID
        self.transcript = transcript; self.outputURL = outputURL; self.createdAt = createdAt
    }
}
