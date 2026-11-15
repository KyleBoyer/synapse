import Foundation

public protocol TranscriptionEngine: Actor {
    func transcribe(wav: URL, language: String?, task: TaskKind,
                    progress: @escaping @Sendable (Double?) -> Void) async throws -> Transcript
    func detectLanguage(wav: URL) async throws -> (code: String, confidence: Double)
    /// Releases framework resources before the ModelManager drops the engine.
    func unload() async
}

extension TranscriptionEngine {
    public func unload() async {}
}

public enum EngineError: Error, LocalizedError, Equatable {
    case unsupported(String)

    public var errorDescription: String? {
        switch self { case .unsupported(let m): return m }
    }
}
