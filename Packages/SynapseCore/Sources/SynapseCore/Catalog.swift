import Foundation

public enum Catalog {
    private static func whisper(_ id: String, _ name: String, _ variant: String, _ mb: Int) -> ModelSpec {
        ModelSpec(id: id, engine: .whisper, displayName: name, variant: variant, approxMB: mb,
                  languages: nil, canTranslate: true, canDetectLanguage: true)
    }

    /// Qwen3.5 small models are natively multimodal: chat plus image input.
    private static func qwen(_ id: String, _ name: String, _ repo: String, _ mb: Int) -> ModelSpec {
        ModelSpec(id: id, engine: .mlx, displayName: name, variant: repo, approxMB: mb,
                  languages: nil, canTranslate: false, canDetectLanguage: false)
    }

    public static let all: [ModelSpec] = [
        whisper("whisper-tiny", "Whisper Tiny", "tiny", 75),
        whisper("whisper-base", "Whisper Base", "base", 145),
        whisper("whisper-small", "Whisper Small", "small", 480),
        whisper("whisper-medium", "Whisper Medium", "medium", 1500),
        whisper("whisper-large-v3", "Whisper Large v3", "large-v3", 3000),
        whisper("whisper-large-v3-turbo", "Whisper Large v3 Turbo", "large-v3-v20240930_turbo", 1600),
        whisper("whisper-large-v3-turbo-q", "Whisper Large v3 Turbo (Quantized)", "large-v3-v20240930_turbo_632MB", 632),
        ModelSpec(id: "distil-large-v3", engine: .whisper, displayName: "Distil Large v3 (English)", variant: "distil-large-v3",
                  approxMB: 1500, languages: ["en"], canTranslate: false, canDetectLanguage: false),
        ModelSpec(id: "parakeet-v3", engine: .parakeet, displayName: "Parakeet v3", variant: "v3", approxMB: 600,
                  languages: Set("bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk".split(separator: " ").map(String.init)),
                  canTranslate: false, canDetectLanguage: false),
        qwen("qwen3.5-0.8b", "Qwen3.5 0.8B", "mlx-community/Qwen3.5-0.8B-4bit", 652),
        qwen("qwen3.5-2b", "Qwen3.5 2B", "mlx-community/Qwen3.5-2B-4bit", 1749),
        qwen("qwen3.5-4b", "Qwen3.5 4B", "mlx-community/Qwen3.5-4B-MLX-4bit", 3061),
        qwen("qwen3.5-9b", "Qwen3.5 9B", "mlx-community/Qwen3.5-9B-MLX-4bit", 5977),
        ModelSpec(id: "parakeet-v2", engine: .parakeet, displayName: "Parakeet v2 (English)", variant: "v2", approxMB: 600,
                  languages: ["en"], canTranslate: false, canDetectLanguage: false),
    ]

    public static func spec(_ id: String) -> ModelSpec? { all.first { $0.id == id } }

    public static let whisperFallbackOrder: [String] = [
        "whisper-large-v3-turbo", "whisper-large-v3-turbo-q", "whisper-large-v3", "whisper-medium", "whisper-small", "whisper-base", "whisper-tiny",
    ]
}

public enum ResolveError: Error, Equatable, LocalizedError {
    case unknownModel(String), notDownloaded(String), noCapableModel, wrongKind(String), noChatModel

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model '\(id)'."
        case .notDownloaded(let id): return "Model '\(id)' is not downloaded."
        case .noCapableModel: return "No downloaded Whisper model can handle this request."
        case .noChatModel: return "No chat model is downloaded. Download one (e.g. qwen3.5-0.8b) in Models."
        case .wrongKind(let id): return "Model '\(id)' cannot be used for this endpoint."
        }
    }
}

public enum ModelResolver {
    public static func resolve(requested: String?, task: TaskKind, language: String?, defaultID: String,
                               downloaded: Set<String>) throws -> ModelSpec {
        let id = (requested == nil || requested == "whisper-1") ? defaultID : requested!
        guard var spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
        guard !spec.isChat else { throw ResolveError.wrongKind(id) }
        if (task == .translate && !spec.canTranslate) || !spec.supports(language: language) {
            guard let fb = whisperFallbackOrder.compactMap(Catalog.spec).first(where: {
                downloaded.contains($0.id) && ($0.canTranslate || task != .translate) && $0.supports(language: language)
            }) else { throw ResolveError.noCapableModel }
            spec = fb
        }
        guard downloaded.contains(spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        return spec
    }

    /// Chat requests: nil picks the smallest downloaded chat model.
    public static func resolveChat(requested: String?, downloaded: Set<String>) throws -> ModelSpec {
        if let id = requested, !id.isEmpty {
            guard let spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
            guard spec.isChat else { throw ResolveError.wrongKind(id) }
            guard downloaded.contains(id) else { throw ResolveError.notDownloaded(id) }
            return spec
        }
        guard let spec = Catalog.all.filter({ $0.isChat && downloaded.contains($0.id) })
            .min(by: { $0.approxMB < $1.approxMB }) else { throw ResolveError.noChatModel }
        return spec
    }

    private static var whisperFallbackOrder: [String] { Catalog.whisperFallbackOrder }

    public static func smallestDetector(downloaded: Set<String>) -> ModelSpec? {
        ["whisper-tiny", "whisper-base", "whisper-small", "whisper-medium", "whisper-large-v3-turbo-q", "whisper-large-v3-turbo", "whisper-large-v3"]
            .compactMap(Catalog.spec).first { downloaded.contains($0.id) && $0.canDetectLanguage }
    }
}
