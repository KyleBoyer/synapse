import Foundation
import Hummingbird
import NIOCore

struct TranscriptionForm: Decodable {
    var file: File
    var model: String?
    var language: String?
    var response_format: String?
}

/// Writes the upload to a per-request temp dir, runs `body`, then deletes the dir.
func withUpload<T>(_ file: File, _ body: (URL) async throws -> T) async throws -> T {
    let ext = URL(fileURLWithPath: file.filename).pathExtension
    let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-upload/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: ext.isEmpty ? "upload.bin" : "upload.\(ext)")
    try Data(buffer: file.data).write(to: url)
    return try await body(url)
}

/// Runs a synchronous API job. Resolve errors are surfaced as 400 before queuing.
func runSync(queue: JobQueue, store: ModelStore, settings: SettingsBox, input: AudioInput,
             model: String?, language: String?, task: TaskKind) async throws -> Transcript {
    _ = try ModelResolver.resolve(requested: model, task: task, language: language,
                                  defaultID: settings.current.defaultModelID, downloaded: await store.downloaded)
    let snap = await queue.run(JobRequest(input: input, modelID: model, language: language, task: task, origin: .api))
    switch snap.status {
    case .done: if let t = snap.transcript { return t }; throw HTTPError(.internalServerError, message: "No transcript produced")
    case .failed(let m): throw HTTPError(.internalServerError, message: m)
    default: throw HTTPError(.internalServerError, message: "Job \(snap.status.apiName)")
    }
}

/// Carries the fields of both OpenAI's and Anthropic's model objects.
struct ModelItem: Encodable {
    var id: String
    var object = "model", owned_by = "synapse", created = 0
    var type = "model", created_at = "1970-01-01T00:00:00Z", lifecycle = "active"
    var display_name: String
}
struct ModelList: Encodable {
    var object = "list"
    var data: [ModelItem]
    var has_more = false
    var first_id: String?, last_id: String?
}

func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

func addOpenAIRoutes(to g: RouterGroup<SynapseContext>, queue: JobQueue, store: ModelStore, settings: SettingsBox) {
    g.get("v1/models") { _, _ in
        var ids = await store.downloaded.filter { Catalog.spec($0) != nil }.sorted()
        if let checkout = settings.current.voomCheckout, !checkout.isEmpty { ids += VOOMRuntime.modelIDs(checkout: checkout, modelsRoot: store.root) }
        return json(ModelList(data: ids.map { ModelItem(id: $0, display_name: Catalog.spec($0)?.displayName ?? $0) },
                             first_id: ids.first, last_id: ids.last))
    }
    for (path, task) in [("v1/audio/transcriptions", TaskKind.transcribe), ("v1/audio/translations", .translate)] {
        g.post(RouterPath(path)) { req, ctx in
            let form = try await req.decode(as: TranscriptionForm.self, context: ctx)
            guard let format = OutputFormat(rawValue: nonEmpty(form.response_format) ?? "json") else {
                throw HTTPError(.badRequest, message: "Unsupported response_format '\(form.response_format ?? "")'.")
            }
            let t = try await withUpload(form.file) {
                try await runSync(queue: queue, store: store, settings: settings, input: .media($0),
                                  model: nonEmpty(form.model), language: nonEmpty(form.language), task: task)
            }
            let out = Subtitles.render(t, as: format, task: task, cueOptions: settings.current.cue)
            return text(out.body, contentType: out.contentType)
        }
    }
}
