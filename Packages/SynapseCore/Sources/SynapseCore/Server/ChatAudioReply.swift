import Foundation
import Hummingbird

/// Spoken replies on Chat Completions (`modalities: ["text", "audio"]`, OpenAI's chat audio). A model that speaks
/// (OmniVoices) answers in its own voice; any other chat model writes the reply and the downloaded TTS speaks it,
/// sentence by sentence while the text is still being generated.
enum ChatAudio {
    /// OpenAI's pcm16 is 24 kHz mono; every reply is produced at this rate.
    static let rate = 24000

    struct Params { let format: AudioFormat; let voice: String? }

    enum Event: Sendable {
        case transcript(String)
        case audio([Float])
        case done(finish: String, usage: ChatUsage)
    }

    /// nil when the request does not ask for audio.
    static func params(modalities: [String]?, audio: JSONValue?, stream: Bool) throws -> Params? {
        guard modalities?.contains("audio") == true else { return nil }
        let name = audio?["format"]?.string ?? "wav"
        let format: AudioFormat
        if name == "pcm16" { format = .pcm } else {
            guard let f = AudioFormat(rawValue: name), f != .pcm else {
                throw HTTPError(.badRequest, message: "audio.format must be one of wav, mp3, flac, opus, aac, pcm16.")
            }
            format = f
        }
        // As OpenAI: a streamed reply arrives in pieces, which only raw PCM can be cut into.
        if stream && format != .pcm { throw HTTPError(.badRequest, message: "Streaming audio requires audio.format pcm16.") }
        return Params(format: format, voice: audio?["voice"]?.string ?? audio?["voice"]?["id"]?.string)
    }

    static func events(spec: ModelSpec, messages: [ChatMessage], options: ChatOptions, voice: String?,
                       chat: ChatService, speech: SpeechService) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    if OmniVoices.canSpeak(spec) {
                        try await ownVoice(spec, messages, options, chat, c)
                    } else {
                        try await textThenSpeech(spec, messages, options, voice, chat, speech, c)
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    private static func ownVoice(_ spec: ModelSpec, _ messages: [ChatMessage], _ options: ChatOptions, _ chat: ChatService,
                                 _ c: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        let voice = try await chat.voice(spec)
        var down: StreamResampler?
        for try await e in voice.respond(messages, options: options) {
            switch e {
            case .text(let t): c.yield(.transcript(t))
            case .audio(let a, let r):
                if down == nil { down = StreamResampler(from: Double(r), to: Double(rate)) }
                c.yield(.audio(down!.convert(a)))
            case .done(let p, let g): c.yield(.done(finish: "stop", usage: ChatUsage(promptTokens: p, completionTokens: g)))
            }
        }
    }

    private static func textThenSpeech(_ spec: ModelSpec, _ messages: [ChatMessage], _ options: ChatOptions, _ voice: String?,
                                       _ chat: ChatService, _ speech: SpeechService,
                                       _ c: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        let tts: ModelSpec
        do { tts = try await speech.resolve(model: nil) } catch {
            throw HTTPError(.badRequest, message: "Audio replies need a speech model (download PocketTTS) or a model that speaks, such as lfm3-omni-2b.")
        }
        func say(_ sentence: String) async throws {
            let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let (r, pcm) = try await speech.synthesize(model: tts, text: String(text.prefix(SpeechService.maxInputCharacters)),
                                                       voice: voice, speed: 1)
            let down = StreamResampler(from: Double(r), to: Double(rate))
            for try await frame in pcm { c.yield(.audio(down.convert(frame))) }
        }
        var splitter = SentenceSplitter()
        // TTS runs on Core ML without the GPU gate, so speaking a finished sentence does not stall the chat model.
        for try await e in try await chat.stream(model: spec, messages: messages, options: options) {
            switch e {
            case .delta(let s):
                c.yield(.transcript(s))
                for sentence in splitter.feed(s) { try await say(sentence) }
            case .toolCall: break
            case .done(let finish, let usage):
                if let rest = splitter.flush() { try await say(rest) }
                c.yield(.done(finish: finish, usage: usage))
            }
        }
    }

    /// The whole reply in the requested format.
    static func encode(_ samples: [Float], as format: AudioFormat, encoder: AudioEncoder) async throws -> Data {
        if format == .pcm { return PCM.pcm16LE(from: samples) }
        // The encoder's WAV header is for streams (unknown length); a whole reply gets its real length.
        if format == .wav { return PCM.wav16(samples, rate: rate) }
        let pcm = AsyncThrowingStream<[Float], Error> { c in c.yield(samples); c.finish() }
        var out = Data()
        for try await chunk in encoder.encode(pcm, sampleRate: rate, as: format) { out.append(chunk) }
        return out
    }

    static func newID() -> String { "audio_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24) }
}

struct ChatAudioWire: Encodable {
    var id: String
    var data: String
    var expires_at: Int
    var transcript: String
}

struct ChatAudioDeltaWire: Encodable {
    var id: String?
    var data: String?
    var expires_at: Int?
    var transcript: String?
}
