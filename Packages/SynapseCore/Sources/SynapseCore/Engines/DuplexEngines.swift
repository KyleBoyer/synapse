import Foundation
import MLX

/// Maps duplex/translation ModelSpecs to engines (vendored speech-swift). The URL is the model folder
/// (`DuplexModels.folder`); loading happens in the engine's init and `unload()` frees the weights.
public enum DuplexEngines {
    /// The duplex models that hold a conversation (Hibiki Zero only translates).
    public static let conversational: Set<String> = ["voicechat-11b", "voicechat-11b-int5", "personaplex-7b"]
    public static let duplex: @Sendable (ModelSpec, URL) async throws -> any DuplexSpeechEngine = { spec, folder in
        switch spec.id {
        case "voicechat-11b", "voicechat-11b-int5": return try await DuplexVoiceChatEngine(folder: folder)
        case "personaplex-7b": return try await DuplexPersonaPlexEngine(folder: folder)
        default: throw EngineError.unsupported("\(spec.displayName) is not a duplex model")
        }
    }
    public static let translator: @Sendable (ModelSpec, URL) async throws -> any SpeechTranslationEngine = { spec, folder in
        guard spec.id == "hibiki-zero-3b" else { throw EngineError.unsupported("\(spec.displayName) is not a translation model") }
        return try await DuplexHibikiEngine(folder: folder)
    }
}

enum DuplexAudio {
    /// Linear-interpolation resample (speech-grade; fine for 16/24 kHz mono).
    static func resample(_ x: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, x.count > 1 else { return x }
        let n = Int(Double(x.count) * Double(to) / Double(from))
        let step = Double(from) / Double(to)
        return (0..<n).map { i in
            let p = Double(i) * step, j = min(Int(p), x.count - 2), f = Float(p - Double(j))
            return x[j] * (1 - f) + x[j + 1] * f
        }
    }

    static func freeMLXMemory() { GPUGate.clearMLXCache() }
}
