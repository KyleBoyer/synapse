import Foundation

/// One step of a full-duplex speech-to-speech model.
public enum DuplexEvent: Sendable, Equatable {
    case audio([Float])
    case assistantText(String)
    case userText(String)
    /// The model called a tool (native tool calling); `arguments` is a JSON object string.
    case toolCall(name: String, arguments: String)
}

/// How a full-duplex model takes tools.
public enum DuplexToolSupport: Sendable, Equatable {
    case none
    /// The model calls tools itself and hears results (NemotronLabs VoiceChat).
    case native
    /// A chat model beside it decides calls from what the user said; the model speaks the answer when it is forced
    /// into its inner monologue (PersonaPlex, the personaplex-tool-calling approach).
    case spokenResults
}

/// Full-duplex models consume microphone audio continuously and emit speech (and optionally text) as they go.
public protocol DuplexSpeechEngine: Actor {
    var inputSampleRate: Int { get }
    var outputSampleRate: Int { get }
    var toolSupport: DuplexToolSupport { get }
    /// Feeds mono Float samples at `inputSampleRate`; returns whatever the model produced for them.
    func push(_ samples: [Float]) async throws -> [DuplexEvent]
    func reset() async
    func unload() async
    /// `.native`: the tools the model may call (a change starts a new conversation).
    func setTools(_ tools: [ChatTool]) async
    /// `.native`: the result of a call the model made.
    func toolResult(name: String, output: String) async throws
    /// `.spokenResults`: says `text` in the model's own voice, as soon as it can.
    func say(_ text: String) async
}

extension DuplexSpeechEngine {
    public var toolSupport: DuplexToolSupport { .none }
    public func setTools(_ tools: [ChatTool]) async {}
    public func toolResult(name: String, output: String) async throws {
        throw EngineError.unsupported("This model does not take tool results.")
    }
    public func say(_ text: String) async {}
}

/// Utterance-level speech translation (e.g. Hibiki Zero: French/Spanish/Portuguese/German to English speech).
public protocol SpeechTranslationEngine: Actor {
    func translate(_ samples: [Float], sampleRate: Int, sourceLanguage: String?) async throws
        -> (audio: [Float], sampleRate: Int, text: String)
    func unload() async
}
