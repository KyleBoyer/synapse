import Foundation
import Hummingbird
import NIOCore

// POST /v1/audio/generations (Synapse's own; OpenAI has no sound-generation endpoint).

private struct SoundParams: Decodable {
    var model: String?
    var prompt: String?
    var seconds: Double?
    var seed: UInt64?
    var response_format: String?
}

func addSoundRoutes(to g: RouterGroup<SynapseContext>, sound: SoundService) {
    g.post("audio/generations") { req, ctx in
        let p = try await decodeJSON(SoundParams.self, req, ctx)
        guard let prompt = nonEmpty(p.prompt) else { throw HTTPError(.badRequest, message: "prompt is required.") }
        let seconds = p.seconds ?? 8
        guard (1...SoundService.maxSeconds).contains(seconds) else {
            throw HTTPError(.badRequest, message: "seconds must be between 1 and \(Int(SoundService.maxSeconds)).")
        }
        guard let format = AudioFormat(rawValue: p.response_format ?? "wav") else {
            throw HTTPError(.badRequest, message: "response_format must be one of \(AudioFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let spec: ModelSpec
        do { spec = try await sound.resolve(nonEmpty(p.model)) } catch { throw HTTPError(.badRequest, message: error.localizedDescription) }
        let clip = try await sound.generate(model: spec, prompt: prompt, seconds: seconds, seed: p.seed)
        // WAV keeps the generator's stereo file; other formats go through the encoder, which takes mono.
        // shortcut: non-WAV formats are mono mixes; pass stereo through AudioEncoder if clients want stereo MP3.
        if format == .wav {
            return Response(status: .ok, headers: [.contentType: format.contentType], body: .init(byteBuffer: ByteBuffer(data: clip.wav)))
        }
        let mono = clip.mono
        let pcm = AsyncThrowingStream<[Float], Error> { c in c.yield(mono); c.finish() }
        var out = Data()
        for try await chunk in sound.encoder.encode(pcm, sampleRate: clip.sampleRate, as: format) { out.append(chunk) }
        return Response(status: .ok, headers: [.contentType: format.contentType], body: .init(byteBuffer: ByteBuffer(data: out)))
    }
}
