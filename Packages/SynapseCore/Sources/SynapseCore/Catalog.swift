import Foundation

public enum Catalog {
    private static func whisper(_ id: String, _ name: String, _ variant: String, _ mb: Int) -> ModelSpec {
        ModelSpec(id: id, engine: .whisper, displayName: name, variant: variant, approxMB: mb,
                  languages: nil, canTranslate: true, canDetectLanguage: true)
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
        ModelSpec(id: "parakeet-v2", engine: .parakeet, displayName: "Parakeet v2 (English)", variant: "v2", approxMB: 600,
                  languages: ["en"], canTranslate: false, canDetectLanguage: false),
    ]

    public static func spec(_ id: String) -> ModelSpec? { all.first { $0.id == id } }

    public static let whisperFallbackOrder: [String] = [
        "whisper-large-v3-turbo", "whisper-large-v3-turbo-q", "whisper-large-v3", "whisper-medium", "whisper-small", "whisper-base", "whisper-tiny",
    ]
}

public enum ResolveError: Error, Equatable, LocalizedError {
    case unknownModel(String), notDownloaded(String), noCapableModel

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model '\(id)'."
        case .notDownloaded(let id): return "Model '\(id)' is not downloaded."
        case .noCapableModel: return "No downloaded Whisper model can handle this request."
        }
    }
}

public enum ModelResolver {
    public static func resolve(requested: String?, task: TaskKind, language: String?, defaultID: String,
                               downloaded: Set<String>) throws -> ModelSpec {
        let id = (requested == nil || requested == "whisper-1") ? defaultID : requested!
        guard var spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
        if (task == .translate && !spec.canTranslate) || !spec.supports(language: language) {
            guard let fb = whisperFallbackOrder.compactMap(Catalog.spec).first(where: {
                downloaded.contains($0.id) && ($0.canTranslate || task != .translate) && $0.supports(language: language)
            }) else { throw ResolveError.noCapableModel }
            spec = fb
        }
        guard downloaded.contains(spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        return spec
    }

    private static var whisperFallbackOrder: [String] { Catalog.whisperFallbackOrder }

    public static func smallestDetector(downloaded: Set<String>) -> ModelSpec? {
        ["whisper-tiny", "whisper-base", "whisper-small", "whisper-medium", "whisper-large-v3-turbo-q", "whisper-large-v3-turbo", "whisper-large-v3"]
            .compactMap(Catalog.spec).first { downloaded.contains($0.id) && $0.canDetectLanguage }
    }
}
