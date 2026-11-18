import Foundation
import VoiceChat

/// Nemotron VoiceChat 11B (16 kHz in, 22.05 kHz out, 80 ms frames). `userText` events carry the new part of the
/// streaming user transcript; `assistantText` the model's text tokens; `audio` is the continuous output stream (silence while idle).
// The actor below is the only user of its model and serializes every call, so handing it to the model's own
// async methods is safe; Swift 6.2 cannot see that and rejects the send.
extension VoiceChatModel: @retroactive @unchecked Sendable {}

public actor DuplexVoiceChatEngine: DuplexSpeechEngine {
    public nonisolated var inputSampleRate: Int { VoiceChatSession.inputSampleRate }
    public nonisolated var outputSampleRate: Int { VoiceChatSession.outputSampleRate }

    private nonisolated(unsafe) var model: VoiceChatModel?
    private var session: VoiceChatSession?
    private var transcript = ""
    private var tools: [ChatTool] = []

    public var toolSupport: DuplexToolSupport { .native }

    init(folder: URL) async throws {
        model = try await VoiceChatModel.load(from: folder)
    }

    private func current() async throws -> VoiceChatSession {
        if let session { return session }
        guard let model else { throw EngineError.unsupported("VoiceChat is unloaded") }
        let s: VoiceChatSession
        if tools.isEmpty {
            s = try await model.startSession(streamUserTranscript: true)
        } else {
            // The checkpoint reads tools from its system prompt and calls them on a separate function channel.
            let prompt = try VoiceChatSession.toolCallingSystemPrompt(availableToolsJSON: Self.toolsJSON(tools))
            s = try await model.startSession(systemPrompt: prompt, streamUserTranscript: true,
                                             turnTaking: .functionCallingRealtime, functionCallingEnabled: true)
        }
        session = s; transcript = ""
        return s
    }

    public func push(_ samples: [Float]) async throws -> [DuplexEvent] {
        await GPUGate.shared.acquire()
        let gate = GateRelease(); defer { gate() }
        let session = try await current()
        if !tools.isEmpty { await session.assistFunctionFastPathIfStalled() }
        let frames = try await session.pushAudio(samples)
        var out: [DuplexEvent] = []
        var audio: [Float] = []
        var text = "", user = ""
        var calls: [DuplexEvent] = []
        let special = model?.tokenizer.specialIDs ?? []
        for f in frames {
            if !special.contains(f.textToken) { text += f.text }
            if let t = f.userTranscript {
                if t.hasPrefix(transcript) { user += t.dropFirst(transcript.count) }
                transcript = t
            }
            // `speaking` marks only text-token frames; the spoken reply runs on past them, so keep every playable frame.
            if f.playbackRequired { audio += f.audio }
            if let payload = f.functionCall { calls += Self.parseCalls(payload) }
        }
        if !user.isEmpty { out.append(.userText(user)) }
        if !text.isEmpty { out.append(.assistantText(text)) }
        if !audio.isEmpty { out.append(.audio(audio)) }
        return out + calls
    }

    public func setTools(_ tools: [ChatTool]) async {
        guard tools != self.tools else { return }
        self.tools = tools
        session = nil; transcript = ""
    }

    public func toolResult(name: String, output: String) async throws {
        guard let session else { throw EngineError.unsupported("No VoiceChat conversation is waiting for a tool result.") }
        // The checkpoint was trained on {"ok", "tool", "result"}; a JSON result goes in as JSON, anything else as text.
        let result = (try? JSONSerialization.jsonObject(with: Data(output.utf8), options: .fragmentsAllowed)) ?? output
        let payload = try JSONSerialization.data(withJSONObject: ["ok": true, "tool": name, "result": result], options: [.sortedKeys])
        try await session.injectFunctionResponse(String(decoding: payload, as: UTF8.self))
    }

    /// Compact ASCII JSON array of {description, name, parameters}, as the checkpoint's prompt expects.
    static func toolsJSON(_ tools: [ChatTool]) throws -> String {
        let list = tools.map { t -> [String: Any] in
            ["description": t.description, "name": t.name,
             "parameters": (try? JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))) ?? ["type": "object", "properties": [:]]]
        }
        let data = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys, .withoutEscapingSlashes])
        // Non-ASCII characters are escaped, since the prompt builder accepts ASCII only.
        return String(decoding: data, as: UTF8.self).unicodeScalars.map { $0.isASCII ? String($0) : String(format: "\\u%04x", $0.value) }.joined()
    }

    /// `<TOOLCALL>[{"name": ..., "arguments": {...}}]</TOOLCALL>` -> one event per call.
    static func parseCalls(_ payload: String) -> [DuplexEvent] {
        let body = payload.replacingOccurrences(of: "<TOOLCALL>", with: "").replacingOccurrences(of: "</TOOLCALL>", with: "")
        guard let list = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]] else { return [] }
        return list.compactMap { call in
            guard let name = call["name"] as? String else { return nil }
            let args = call["arguments"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            return .toolCall(name: name, arguments: args.map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        }
    }

    public func reset() async { session = nil; transcript = "" }

    public func unload() async {
        session = nil; model = nil; transcript = ""
        DuplexAudio.freeMLXMemory()
    }
}
