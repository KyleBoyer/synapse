import Foundation
import Hummingbird

struct CreateJob: Decodable {
    var path: String
    var model: String?
    var language: String?
    var task: TaskKind?
    var force: Bool?
}

struct JobDTO: Encodable {
    let id: String, status: String, progress: Double?, source: String, output: String?, model: String?, error: String?, created_at: String

    init(_ j: JobSnapshot) {
        id = j.id.uuidString
        status = j.status.apiName
        if case .transcribing(let p) = j.status { progress = p } else { progress = j.status == .done ? 1 : nil }
        source = j.request.input.url.path
        output = j.outputURL?.path
        model = j.modelID
        if case .failed(let m) = j.status { error = m } else if case .skipped(let m) = j.status { error = m } else { error = nil }
        created_at = ISO8601DateFormatter().string(from: j.createdAt)
    }

    // Explicit so nil fields are emitted as null, matching the documented shape.
    func encode(to encoder: Encoder) throws {
        enum K: String, CodingKey { case id, status, progress, source, output, model, error, created_at }
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(status, forKey: .status); try c.encode(progress, forKey: .progress)
        try c.encode(source, forKey: .source); try c.encode(output, forKey: .output); try c.encode(model, forKey: .model)
        try c.encode(error, forKey: .error); try c.encode(created_at, forKey: .created_at)
    }
}

func addJobRoutes(to g: RouterGroup<SynapseContext>, queue: JobQueue, settings: SettingsBox) {
    g.post("v1/jobs") { req, ctx in
        let body = try await req.decode(as: CreateJob.self, context: ctx)
        guard PathPolicy.isAllowed(body.path, roots: settings.current.allowedRoots) else {
            throw HTTPError(.forbidden, message: "Path is outside the allowed library roots.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: body.path, isDirectory: &isDir), !isDir.boolValue else {
            throw HTTPError(.notFound, message: "File not found.")
        }
        let url = URL(fileURLWithPath: body.path)
        let id = await queue.submit(JobRequest(input: .media(url), modelID: nonEmpty(body.model), language: nonEmpty(body.language),
                                               task: body.task ?? .transcribe, writeSidecarNextTo: url,
                                               force: body.force ?? false, origin: .api))
        let status = await queue.snapshot(id)?.status.apiName ?? "queued"
        return json(["id": id.uuidString, "status": status], status: .accepted)
    }

    g.get("v1/jobs") { _, _ in
        json(["data": await queue.all().map(JobDTO.init)])
    }

    g.get("v1/jobs/:id") { _, ctx in
        guard let id = ctx.parameters.get("id").flatMap(UUID.init(uuidString:)), let j = await queue.snapshot(id) else {
            throw HTTPError(.notFound, message: "No such job.")
        }
        return json(JobDTO(j))
    }

    g.delete("v1/jobs/:id") { _, ctx in
        guard let id = ctx.parameters.get("id").flatMap(UUID.init(uuidString:)), await queue.snapshot(id) != nil else {
            throw HTTPError(.notFound, message: "No such job.")
        }
        await queue.cancel(id)
        return json(["status": "cancelled"])
    }
}
