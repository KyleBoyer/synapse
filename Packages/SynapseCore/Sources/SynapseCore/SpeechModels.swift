import Foundation
@preconcurrency import FluidAudio

/// Downloads and locates FluidAudio realtime components (streaming ASR, VAD, TTS).
/// Each component keeps its files under `<root>/speech/<variant>`, never FluidAudio's own cache folder.
enum SpeechModels {
    static func folder(_ spec: ModelSpec, root: URL) -> URL {
        root.appending(path: "speech/\(spec.variant)", directoryHint: .isDirectory)
    }

    /// FluidAudio managers download into the directory they are given when the files are missing,
    /// so "download" is a load-then-release against our folder.
    static func download(_ spec: ModelSpec, root: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dir = folder(spec, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let handler: ProgressHandler = { progress($0.fractionCompleted) }
        switch spec.id {
        case "parakeet-eou-120m":
            let m = StreamingEouAsrManager(chunkSize: .ms160)
            try await m.loadModels(to: dir, progressHandler: handler)
            await m.cleanup()
        case "silero-vad":
            _ = try await VadManager(modelDirectory: dir, progressHandler: handler)
        case "pocket-tts":
            let m = PocketTtsManager(directory: dir)
            try await m.initialize()
            await m.cleanup()
        case "speaker-diarizer":
            // Downloads and compiles the offline pipeline's Core ML models into `dir`; a second call reuses them.
            let m = OfflineDiarizerManager()
            try await m.prepareModels(directory: dir)
        case "kokoro-82m":
            let m = KokoroAneManager(directory: dir)
            try await m.initialize()
            await m.cleanup()
        default:
            throw EngineError.unsupported("\(spec.displayName) download is not implemented yet")
        }
        progress(1)
        return dir
    }
}
