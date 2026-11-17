import Foundation
import Hummingbird

// OpenAI custom voices: POST /v1/audio/voice_consents, then POST /v1/audio/voices with the consent id, then
// `voice: {"id": "voice_…"}` on /v1/audio/speech. Voices are cloned by PocketTTS.

private struct ConsentForm: Decodable {
    var name: String?
    var language: String?
    var recording: File?
}

private struct VoiceForm: Decodable {
    var name: String?
    var audio_sample: File?
    var consent: String?
    var type: String?
}

private struct RenameBody: Decodable { var name: String? }

private let maxUpload = 10 * 1024 * 1024

extension VoiceConsent {
    var wire: AnyEncodableDict {
        AnyEncodableDict(["id": id, "object": "audio.voice_consent", "name": name, "language": language, "created_at": createdAt])
    }
}

extension CustomVoice {
    var wire: AnyEncodableDict {
        AnyEncodableDict(["id": id, "object": "audio.voice", "name": name, "type": "audio_sample", "created_at": createdAt])
    }
}

func addVoiceRoutes(to g: RouterGroup<SynapseContext>, speech: SpeechService) {
    let library = speech.voices
    @Sendable func bad(_ m: String) -> HTTPError { HTTPError(.badRequest, message: m) }
    @Sendable func required(_ v: String?, _ field: String) throws -> String {
        guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { throw bad("\(field) is required.") }
        return v
    }
    @Sendable func upload(_ f: File?, _ field: String) throws -> File {
        guard let f, f.data.readableBytes > 0 else { throw bad("\(field) is required.") }
        guard f.data.readableBytes <= maxUpload else { throw bad("\(field) must be at most 10 MiB.") }
        return f
    }

    g.post("audio/voice_consents") { req, ctx in
        let form = try await req.decode(as: ConsentForm.self, context: ctx)
        let name = try required(form.name, "name"), language = try required(form.language, "language")
        let recording = try upload(form.recording, "recording")
        let consent = try await withUpload(recording) { try await library.addConsent(name: name, language: language, recording: $0) }
        return json(consent.wire)
    }

    // OpenAI cursor paging: `after` (an id) and `limit` (1–100, default 20).
    g.get("audio/voice_consents") { req, _ in
        var all = await library.consents()
        if let after = req.uri.queryParameters.get("after"), let i = all.firstIndex(where: { $0.id == after }) { all = Array(all[(i + 1)...]) }
        let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) ?? 20
        guard (1...100).contains(limit) else { throw bad("limit must be between 1 and 100.") }
        let page = Array(all.prefix(limit))
        return json(AnyEncodableDict(["object": "list", "data": page.map(\.wire), "has_more": all.count > limit,
                                      "first_id": page.first?.id, "last_id": page.last?.id]))
    }

    g.get("audio/voice_consents/:id") { _, ctx in
        let id = ctx.parameters.get("id") ?? ""
        guard let c = await library.consent(id) else { return apiError(.notFound, "No voice consent '\(id)'.") }
        return json(c.wire)
    }

    g.post("audio/voice_consents/:id") { req, ctx in
        let id = ctx.parameters.get("id") ?? ""
        let name = try required(try await decodeJSON(RenameBody.self, req, ctx).name, "name")
        guard let c = try await library.renameConsent(id, to: name) else { return apiError(.notFound, "No voice consent '\(id)'.") }
        return json(c.wire)
    }

    g.delete("audio/voice_consents/:id") { _, ctx in
        let id = ctx.parameters.get("id") ?? ""
        guard await library.deleteConsent(id) else { return apiError(.notFound, "No voice consent '\(id)'.") }
        return json(AnyEncodableDict(["id": id, "object": "audio.voice_consent", "deleted": true]))
    }

    g.post("audio/voices") { req, ctx in
        let form = try await req.decode(as: VoiceForm.self, context: ctx)
        if let type = form.type, type != "audio_sample" {
            throw bad("Only audio_sample voices are supported; Synapse cannot design a voice from a text prompt.")
        }
        let name = try required(form.name, "name"), consent = try required(form.consent, "consent")
        let sample = try upload(form.audio_sample, "audio_sample")
        do {
            let voice = try await withUpload(sample) { try await speech.createVoice(name: name, sample: $0, consentID: consent) }
            return json(voice.wire)
        } catch let e as SpeechError { throw bad(e.localizedDescription) }
          catch let e as DecodeError { throw bad("Could not read audio_sample: \(e.localizedDescription)") }
    }

    // Not in OpenAI's API (it lists voices only in its dashboard); here so clients and the app can show what exists.
    g.get("audio/voices") { _, _ in
        json(AnyEncodableDict(["object": "list", "data": await library.voices().map(\.wire), "has_more": false]))
    }

    g.delete("audio/voices/:id") { _, ctx in
        let id = ctx.parameters.get("id") ?? ""
        guard await library.deleteVoice(id) else { return apiError(.notFound, "No voice '\(id)'.") }
        return json(AnyEncodableDict(["id": id, "object": "audio.voice.deleted", "deleted": true]))
    }
}
