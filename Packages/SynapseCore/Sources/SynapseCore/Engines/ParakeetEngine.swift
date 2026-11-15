import Foundation
@preconcurrency import FluidAudio

public actor ParakeetEngine: TranscriptionEngine {
    private let manager: AsrManager

    public init(folder: URL, variant: String) async throws {
        let models = try await AsrModels.load(from: folder, version: ParakeetEngine.version(variant))
        manager = AsrManager(config: .default)
        try await manager.loadModels(models)
    }

    static func version(_ variant: String) -> AsrModelVersion { variant == "v2" ? .v2 : .v3 }

    public func transcribe(wav: URL, language: String?, task: TaskKind,
                           progress: @escaping @Sendable (Double?) -> Void) async throws -> Transcript {
        guard task == .transcribe else { throw EngineError.unsupported("Parakeet cannot translate") }
        progress(nil)
        var state = try TdtDecoderState()
        let r = try await manager.transcribe(wav, decoderState: &state)
        try Task.checkCancellation()
        let tokens = (r.tokenTimings ?? []).map { ParakeetWords.Token(text: $0.token, start: $0.startTime, end: $0.endTime) }
        var segments = ParakeetWords.segments(from: ParakeetWords.words(from: tokens))
        if segments.isEmpty, !r.text.isEmpty {
            segments = [Segment(start: 0, end: r.duration, text: r.text)]
        }
        return Transcript(language: language, duration: r.duration, segments: segments)
    }

    public func detectLanguage(wav: URL) async throws -> (code: String, confidence: Double) {
        throw EngineError.unsupported("Parakeet cannot detect language")
    }
}
