import Foundation
@preconcurrency import WhisperKit

public actor WhisperEngine: TranscriptionEngine {
    private let kit: WhisperKit

    public init(folder: URL) async throws {
        // WhisperKit's hub client defaults tokenizers to ~/Documents/huggingface, which triggers a
        // Documents-access prompt in the app. Keep them beside the models: <root>/whisperkit/models/openai/...
        var base = folder
        while base.pathComponents.count > 1, base.lastPathComponent != "whisperkit" { base.deleteLastPathComponent() }
        if base.lastPathComponent != "whisperkit" { base = folder }
        kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder.path, tokenizerFolder: base,
            verbose: false, logLevel: .error, prewarm: false, load: true, download: false))
    }

    public func transcribe(wav: URL, language: String?, task: TaskKind,
                           progress: @escaping @Sendable (Double?) -> Void) async throws -> Transcript {
        let options = DecodingOptions(
            task: task == .translate ? .translate : .transcribe,
            language: language,
            // WhisperKit defaults detectLanguage to false; without this, auto mode assumes English.
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad)

        let kitProgress = kit.progress
        let poller = Task {
            while !Task.isCancelled {
                let f = kitProgress.fractionCompleted
                progress(f > 0 ? min(f, 1) : nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poller.cancel() }

        let results = try await kit.transcribe(
            audioPath: wav.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: options,
            callback: { _ in Task.isCancelled ? false : nil })
        try Task.checkCancellation()

        let segments = results.flatMap(\.segments).map { s in
            Segment(start: Double(s.start), end: Double(s.end), text: s.text,
                    words: (s.words ?? []).map { Word(start: Double($0.start), end: Double($0.end), text: $0.word) })
        }
        let duration = segments.last?.end ?? 0
        return Transcript(language: task == .translate ? "en" : results.first?.language,
                          duration: duration, segments: segments)
    }

    public func unload() async { await kit.unloadModels() }

    public func detectLanguage(wav: URL) async throws -> (code: String, confidence: Double) {
        let r = try await kit.detectLanguage(audioPath: wav.path)
        // langProbs are log-probabilities.
        return (r.language, exp(Double(r.langProbs[r.language] ?? -.infinity)))
    }
}
