import Foundation

/// Maps image ModelSpecs to engines. Backends are filled in per family (FLUX.2, Z-Image, mflux).
public enum ImageEngines {
    public static let real: ImageService.EngineFactory = { spec, _ in
        throw EngineError.unsupported("Image engine for \(spec.engine.rawValue) is not available yet")
    }
}
