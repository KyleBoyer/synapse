import Foundation
import VoiceChat

/// Nemotron VoiceChat 11B (16 kHz in, 22.05 kHz out, 80 ms frames). `userText` events carry the new part of the
/// streaming user transcript; `assistantText` the model's text tokens; `audio` is the continuous output stream (silence while idle).
public actor DuplexVoiceChatEngine: DuplexSpeechEngine {
    public nonisolated var inputSampleRate: Int { VoiceChatSession.inputSampleRate }
    public nonisolated var outputSampleRate: Int { VoiceChatSession.outputSampleRate }

    private nonisolated(unsafe) var model: VoiceChatModel?
    private var session: VoiceChatSession?
    private var transcript = ""

    init(folder: URL) async throws {
        model = try await VoiceChatModel.load(from: folder)
    }

    private func current() async throws -> VoiceChatSession {
        if let session { return session }
        guard let model else { throw EngineError.unsupported("VoiceChat is unloaded") }
        let s = try await model.startSession(streamUserTranscript: true)
        session = s; transcript = ""
        return s
    }

    public func push(_ samples: [Float]) async throws -> [DuplexEvent] {
        await GPUGate.shared.acquire()
        let gate = GateRelease(); defer { gate() }
        let frames = try await current().pushAudio(samples)
        var out: [DuplexEvent] = []
        var audio: [Float] = []
        var text = "", user = ""
        let special = model?.tokenizer.specialIDs ?? []
        for f in frames {
            if !special.contains(f.textToken) { text += f.text }
            if let t = f.userTranscript {
                if t.hasPrefix(transcript) { user += t.dropFirst(transcript.count) }
                transcript = t
            }
            // `speaking` marks only text-token frames; the spoken reply runs on past them, so keep every playable frame.
            if f.playbackRequired { audio += f.audio }
        }
        if !user.isEmpty { out.append(.userText(user)) }
        if !text.isEmpty { out.append(.assistantText(text)) }
        if !audio.isEmpty { out.append(.audio(audio)) }
        return out
    }

    public func reset() async { session = nil; transcript = "" }

    public func unload() async {
        session = nil; model = nil; transcript = ""
        DuplexAudio.freeMLXMemory()
    }
}
