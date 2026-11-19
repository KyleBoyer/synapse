import Foundation
import Hummingbird
import NIOCore

// POST /v1/audio/generations (Synapse's own; OpenAI has no sound-generation endpoint).

private struct SoundParams: Decodable {
    var model: String?
    var prompt: String?
    /// Sung by models that take lyrics (MiniMax Music 3), with section tags like [verse] on their own lines.
    var lyrics: String?
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
        let clip = try await sound.generate(model: spec, prompt: prompt, lyrics: nonEmpty(p.lyrics), seconds: seconds, seed: p.seed)
        return Response(status: .ok, headers: [.contentType: format.contentType],
                        body: .init(byteBuffer: ByteBuffer(data: try await sound.encoded(clip, as: format))))
    }

    // Audio to audio (ours): a recording in, the cleaned recording out.
    g.post("audio/enhance") { req, ctx in
        let (form, format) = try await editForm(req, ctx)
        let tracks = try await runEdit(sound, form, task: .enhance)
        return Response(status: .ok, headers: [.contentType: format.contentType],
                        body: .init(byteBuffer: ByteBuffer(data: try await sound.encoded(tracks.1[0].clip, as: format))))
    }

    // A recording in, named tracks out as base64 (several files do not fit one audio response).
    g.post("audio/separate") { req, ctx in
        let (form, format) = try await editForm(req, ctx)
        let (spec, tracks) = try await runEdit(sound, form, task: .separate)
        var out: [SeparatedTrack] = []
        for t in tracks {
            out.append(SeparatedTrack(name: t.name, format: format.rawValue, seconds: (t.clip.seconds * 100).rounded() / 100,
                                      audio: try await sound.encoded(t.clip, as: format).base64EncodedString()))
        }
        return json(SeparationResponse(model: spec.id, tracks: out))
    }
}

private struct SeparatedTrack: Encodable { var name, format: String; var seconds: Double; var audio: String }
private struct SeparationResponse: Encodable { var model: String; var tracks: [SeparatedTrack] }

private struct AudioEditForm: Decodable {
    var file: File
    var model: String?
    var prompt: String?
    var response_format: String?
}

private func editForm(_ req: Request, _ ctx: SynapseContext) async throws -> (AudioEditForm, AudioFormat) {
    let form = try await req.decode(as: AudioEditForm.self, context: ctx)
    guard let format = AudioFormat(rawValue: form.response_format ?? "wav") else {
        throw HTTPError(.badRequest, message: "response_format must be one of \(AudioFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    return (form, format)
}

private func runEdit(_ sound: SoundService, _ form: AudioEditForm, task: AudioEditTask) async throws -> (ModelSpec, [AudioTrack]) {
    let prompt = nonEmpty(form.prompt)
    do {
        let spec = try await sound.resolveEdit(nonEmpty(form.model), task: task, prompt: prompt)
        return (spec, try await withUpload(form.file) { try await sound.edit(model: spec, input: $0, prompt: prompt) })
    } catch let e as SoundError {
        if case .noEditModel = e { throw HTTPError(.serviceUnavailable, message: e.localizedDescription) }
        throw HTTPError(.badRequest, message: e.localizedDescription)
    }
}
