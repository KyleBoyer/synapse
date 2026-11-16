import Foundation

/// One step of a full-duplex speech-to-speech model.
public enum DuplexEvent: Sendable, Equatable {
    case audio([Float])
    case assistantText(String)
    case userText(String)
}

/// Full-duplex models consume microphone audio continuously and emit speech (and optionally text) as they go.
public protocol DuplexSpeechEngine: Actor {
    var inputSampleRate: Int { get }
    var outputSampleRate: Int { get }
    /// Feeds mono Float samples at `inputSampleRate`; returns whatever the model produced for them.
    func push(_ samples: [Float]) async throws -> [DuplexEvent]
    func reset() async
    func unload() async
}

/// Utterance-level speech translation (e.g. Hibiki Zero: French/Spanish/Portuguese/German to English speech).
public protocol SpeechTranslationEngine: Actor {
    func translate(_ samples: [Float], sampleRate: Int, sourceLanguage: String?) async throws
        -> (audio: [Float], sampleRate: Int, text: String)
    func unload() async
}
