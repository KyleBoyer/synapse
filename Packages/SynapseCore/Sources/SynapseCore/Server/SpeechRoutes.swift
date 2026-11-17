import Foundation
import Hummingbird
import NIOCore

// OpenAI Audio API: POST /v1/audio/speech.

private struct SpeechParams: Decodable {
    var model: String?
    var input: String?
    var voice: Voice?
    var response_format: String?
    var speed: Double?
    var stream_format: String?

    /// The SDK sends a string; newer clients send `{ "id": ... }`.
    struct Voice: Decodable {
        let name: String
        init(from d: Decoder) throws {
            if let s = try? d.singleValueContainer().decode(String.self) { name = s; return }
            name = try d.container(keyedBy: Key.self).decode(String.self, forKey: .id)
        }
        enum Key: String, CodingKey { case id }
    }
}

func addSpeechRoutes(to g: RouterGroup<SynapseContext>, speech: SpeechService) {
    g.post("audio/speech") { req, ctx in
        let p = try await decodeJSON(SpeechParams.self, req, ctx)
        let input = p.input ?? ""
        guard !input.isEmpty else { throw HTTPError(.badRequest, message: "input is required.") }
        guard input.count <= SpeechService.maxInputCharacters else {
            throw HTTPError(.badRequest, message: SpeechError.badInput.localizedDescription)
        }
        guard let format = AudioFormat(rawValue: p.response_format ?? "mp3") else {
            throw HTTPError(.badRequest, message: "response_format must be one of \(AudioFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let speed = p.speed ?? 1.0
        guard (0.25...4.0).contains(speed) else { throw HTTPError(.badRequest, message: "speed must be between 0.25 and 4.0.") }
        let streamFormat = p.stream_format ?? "audio"
        guard ["audio", "sse"].contains(streamFormat) else { throw HTTPError(.badRequest, message: "stream_format must be audio or sse.") }

        let model: ModelSpec
        do { model = try await speech.resolve(model: p.model) } catch let e as ResolveError {
            throw HTTPError(.badRequest, message: e.localizedDescription)
        } catch let e as SpeechError { throw HTTPError(.serviceUnavailable, message: e.localizedDescription) }
        let rate: Int, pcm: AsyncThrowingStream<[Float], Error>
        do { (rate, pcm) = try await speech.synthesize(model: model, text: input, voice: p.voice?.name, speed: speed) } catch let e as SpeechError {
            throw HTTPError(.badRequest, message: e.localizedDescription)
        }
        let encoded = speech.encoder.encode(pcm, sampleRate: rate, as: format)

        if streamFormat == "sse" {
            return sse { write in
                for try await chunk in encoded {
                    try await write(nil, AnyEncodableDict(["type": "speech.audio.delta", "audio": chunk.base64EncodedString()]))
                }
                try await write(nil, AnyEncodableDict(["type": "speech.audio.done",
                                                       "usage": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0]]))
            }
        }
        let body = ResponseBody { writer in
            for try await chunk in encoded { try await writer.write(ByteBuffer(data: chunk)) }
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: [.contentType: format.contentType], body: body)
    }
}
