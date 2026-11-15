import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

struct ASRForm: Decodable { var audio_file: File }

func addASRRoutes(to g: RouterGroup<SynapseContext>, queue: JobQueue, store: ModelStore, settings: SettingsBox) {
    g.post("asr") { req, ctx in
        let q = req.uri.queryParameters
        let task = TaskKind(rawValue: q.get("task") ?? "transcribe") ?? .transcribe
        let output = OutputFormat(rawValue: q.get("output") ?? "txt") ?? .txt
        let encode = q.get("encode").map { $0.lowercased() != "false" } ?? true
        let form = try await req.decode(as: ASRForm.self, context: ctx)
        let s = settings.current
        let t = try await withUpload(form.audio_file) {
            try await runSync(queue: queue, store: store, settings: settings,
                              input: encode ? .media($0) : .pcm16le($0),
                              model: s.bazarrModelID, language: nonEmpty(q.get("language")), task: task)
        }
        let body = Subtitles.render(t, as: output, task: task, cueOptions: s.cue).body
        let stem = URL(fileURLWithPath: form.audio_file.filename).deletingPathExtension().lastPathComponent
        return text(body, contentType: "text/plain", extra: [
            .contentDisposition: "attachment; filename=\"\(stem).\(output.rawValue)\"",
            HTTPField.Name("Asr-Engine")!: "synapse",
        ])
    }

    g.post("detect-language") { req, ctx in
        let encode = req.uri.queryParameters.get("encode").map { $0.lowercased() != "false" } ?? true
        let form = try await req.decode(as: ASRForm.self, context: ctx)
        let found = try await withUpload(form.audio_file) {
            try await queue.detectLanguage(encode ? .media($0) : .pcm16le($0))
        }
        // Bazarr ignores HTTP status, so "no detector" is a 200 with `und`.
        guard let found else {
            return json(DetectResponse(detected_language: "unknown", language_code: "und", confidence: 0))
        }
        let name = Locale(identifier: "en").localizedString(forLanguageCode: found.code)?.lowercased() ?? found.code
        return json(DetectResponse(detected_language: name, language_code: found.code, confidence: found.confidence))
    }
}

struct DetectResponse: Encodable { var detected_language: String; var language_code: String; var confidence: Double }
