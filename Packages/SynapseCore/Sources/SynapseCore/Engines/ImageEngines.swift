import Foundation

/// Maps image ModelSpecs to their backend. Each backend lives in its own file.
public enum ImageEngines {
    public static let real: ImageService.EngineFactory = { spec, folder in
        switch spec.engine {
        case .flux2: return try await Flux2ImageEngine(spec: spec, folder: folder)
        case .zimage: return try await ZImageEngine(spec: spec, folder: folder)
        case .mflux: return try await MFluxImageEngine(spec: spec, folder: folder)
        case .whisper, .parakeet, .mlx, .speech, .duplex: throw ResolveError.wrongKind(spec.id)
        }
    }
}
