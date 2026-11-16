import Foundation
import HibikiTranslate
import PersonaPlex

/// Kyutai Hibiki Zero 3B: French/Spanish/Portuguese/German speech to English speech + text, per utterance.
public actor DuplexHibikiEngine: SpeechTranslationEngine {
    private var model: HibikiTranslateModel?
    private let spm: SentencePieceDecoder?
    static let sampleRate = 24_000

    init(folder: URL) async throws {
        model = try await HibikiTranslateModel.fromPretrained(
            modelId: HibikiTranslateModel.modelId8bit, cacheDir: folder, offlineMode: true)
        spm = try? SentencePieceDecoder(modelPath: folder.appending(path: "tokenizer_spm_48k_multi6_2.model").path)
    }

    public func translate(_ samples: [Float], sampleRate: Int, sourceLanguage: String?) async throws
        -> (audio: [Float], sampleRate: Int, text: String) {
        guard let model else { throw EngineError.unsupported("Hibiki Zero is unloaded") }
        let lang = sourceLanguage.flatMap { HibikiSourceLanguage(rawValue: String($0.prefix(2)).lowercased()) } ?? .fr  // hint only, model auto-detects
        let out = model.translate(sourceAudio: DuplexAudio.resample(samples, from: sampleRate, to: Self.sampleRate), sourceLanguage: lang)
        return (out.audio, Self.sampleRate, spm?.decode(out.textTokens) ?? "")
    }

    public func unload() async {
        model = nil
        DuplexAudio.freeMLXMemory()
    }
}
