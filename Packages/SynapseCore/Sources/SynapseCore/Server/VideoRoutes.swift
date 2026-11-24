import Foundation
import Hummingbird

/// OpenAI Videos API (`openai.types.Video`): create, poll, download, list, delete.
func addVideoRoutes(to g: RouterGroup<SynapseContext>, videos: VideoService) {
    g.post("videos") { req, ctx in
        let fields: [String: String], image: Data?
        var loraList: Any?
        if req.headers[.contentType]?.hasPrefix("multipart/form-data") == true {
            let form = try await parseMultipart(req, ctx, fileFields: ["input_reference"])
            fields = form.fields; image = form.files.first?.data
        } else {
            let raw = try await rawBody(req, ctx)
            guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw HTTPError(.badRequest, message: "Body must be a JSON object or multipart form.")
            }
            fields = o.compactMapValues { v in (v as? String) ?? (v as? NSNumber).map { "\($0)" } }
            image = nil; loraList = o["loras"]
        }
        guard let prompt = nonEmpty(fields["prompt"]) else { throw HTTPError(.badRequest, message: "prompt is required.") }
        let seconds = fields["seconds"] ?? "4"
        guard let s = Int(seconds), [4, 8, 12].contains(s) else {
            throw HTTPError(.badRequest, message: "seconds must be \"4\", \"8\" or \"12\".")
        }
        let sizeText = fields["size"] ?? "768x512"
        let size = sizeText.split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, size.allSatisfy({ (256...1920).contains($0) }) else {
            throw HTTPError(.badRequest, message: "size must be WIDTHxHEIGHT, each side from 256 to 1920 (for example 1280x720).")
        }
        // LTX needs multiples of 64, OpenAI's sizes are not (1280x720), so generate at the nearest smaller multiple.
        let width = size[0] / 64 * 64, height = size[1] / 64 * 64
        let spec: ModelSpec
        let loras = try parseLoRAs(loraList, single: nonEmpty(fields["lora"]), strength: fields["lora_strength"])
        do {
            spec = try await videos.resolve(nonEmpty(fields["model"]))
            for use in loras { _ = try await videos.addOnFile(use.id, for: spec) }
        } catch { throw HTTPError(.badRequest, message: error.localizedDescription) }
        let job = await videos.create(model: spec, request: VideoRequest(
            prompt: prompt, width: width, height: height, frames: VideoService.frames(seconds: s),
            seed: fields["seed"].flatMap { UInt64($0) }, inputImage: image, loras: loras), size: sizeText)
        return videoResponse(videoJSON(job))
    }
    g.get("videos") { req, _ in
        let limit = req.uri.queryParameters.get("limit").flatMap { Int($0) } ?? 20
        let all = await videos.all()
        let page = Array(all.prefix(max(1, min(100, limit))))
        return videoResponse(["object": "list", "data": page.map(videoJSON), "has_more": all.count > page.count,
                              "first_id": page.first?.id ?? NSNull(), "last_id": page.last?.id ?? NSNull()])
    }
    g.get("videos/:id") { _, ctx in
        videoResponse(videoJSON(try await job(ctx, videos)))
    }
    g.get("videos/:id/content") { req, ctx in
        let browser = req.headers[.accept]?.contains("text/html") == true
        let id = ctx.parameters.get("id") ?? ""
        let found = await videos.job(id)
        // Chat apps open this link in a browser while the video renders: a page that follows the job beats an error.
        if browser, found?.status != .completed { return videoStatusPage(found, id: id) }
        guard let j = found else { throw HTTPError(.notFound, message: "No video with id '\(id)'.") }
        guard j.status == .completed, let file = j.file else {
            throw HTTPError(.notFound, message: j.status == .failed ? "Video failed: \(j.error ?? "unknown error")"
                            : "Video is not ready: \(j.status.rawValue), \(j.progress)% done.")
        }
        switch req.uri.queryParameters.get("variant") ?? "video" {
        case "video":
            let data = try Data(contentsOf: file)
            return Response(status: .ok, headers: [.contentType: "video/mp4"], body: .init(byteBuffer: ByteBuffer(data: data)))
        case "thumbnail":
            guard let jpeg = await VideoFile.thumbnail(of: file) else { throw HTTPError(.internalServerError, message: "Could not read the video.") }
            return Response(status: .ok, headers: [.contentType: "image/jpeg"], body: .init(byteBuffer: ByteBuffer(data: jpeg)))
        default:
            throw HTTPError(.badRequest, message: "variant must be video or thumbnail; spritesheet is not supported.")
        }
    }
    g.delete("videos/:id") { _, ctx in
        let id = ctx.parameters.get("id") ?? ""
        guard await videos.delete(id) else { throw HTTPError(.notFound, message: "No video with id '\(id)'.") }
        return videoResponse(["id": id, "object": "video.deleted", "deleted": true])
    }
    for unsupported in ["videos/:id/remix", "videos/:id/extend", "videos/edits", "videos/characters"] {
        g.post(RouterPath(unsupported)) { _, _ -> Response in
            throw HTTPError(.badRequest, message: "Remix, extend, edit and characters are not supported.")
        }
    }
}

/// `loras: [{"id": ..., "strength": 0.8}]` (JSON), or one `lora` with an optional `lora_strength` (JSON or form).
private func parseLoRAs(_ list: Any?, single: String?, strength: String?) throws -> [LoRAUse] {
    let bad = HTTPError(.badRequest, message: "loras must be a list of {\"id\": \"<lora model id>\", \"strength\": <number from -2 to 2>}.")
    var out: [LoRAUse] = []
    if let list {
        guard let items = list as? [Any] else { throw bad }
        for item in items {
            if let id = item as? String { out.append(LoRAUse(id)); continue }
            guard let o = item as? [String: Any], let id = o["id"] as? String else { throw bad }
            var use = LoRAUse(id)
            if let v = o["strength"] {
                guard let n = v as? NSNumber else { throw bad }
                use.strength = n.doubleValue
            }
            out.append(use)
        }
    }
    if let single {
        var use = LoRAUse(single)
        if let strength {
            guard let v = Double(strength) else { throw HTTPError(.badRequest, message: "lora_strength must be a number from -2 to 2.") }
            use.strength = v
        }
        out.append(use)
    }
    guard out.allSatisfy({ LoRAUse.strengths.contains($0.strength) }) else {
        throw HTTPError(.badRequest, message: "LoRA strength must be from -2 to 2.")
    }
    guard Set(out.map(\.id)).count == out.count else { throw HTTPError(.badRequest, message: "Each LoRA can be listed once.") }
    return out
}

private func job(_ ctx: SynapseContext, _ videos: VideoService) async throws -> VideoJob {
    let id = ctx.parameters.get("id") ?? ""
    guard let j = await videos.job(id) else { throw HTTPError(.notFound, message: "No video with id '\(id)'.") }
    return j
}

func videoJSON(_ j: VideoJob) -> [String: Any] {
    let created = Int(j.createdAt.timeIntervalSince1970)
    return [
        "id": j.id, "object": "video", "model": j.model, "status": j.status.rawValue, "progress": j.progress,
        "created_at": created,
        "completed_at": j.completedAt.map { Int($0.timeIntervalSince1970) } ?? NSNull(),
        "expires_at": j.status == .completed ? created + 86_400 : NSNull(),
        "prompt": j.prompt, "seconds": "\(j.seconds)", "size": j.size, "remixed_from_video_id": NSNull(),
        "error": j.error.map { ["code": "generation_failed", "message": $0] } ?? NSNull(),
    ]
}

private func videoResponse(_ o: [String: Any]) -> Response {
    let data = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
}

/// What a browser sees at a video's link before it is ready: the job's state, refreshed every 10 seconds.
func videoStatusPage(_ j: VideoJob?, id: String) -> Response {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    let title: String, detail: String, refresh: Bool
    switch j?.status {
    case nil:
        (title, detail, refresh) = ("Unknown video", "Synapse has no video with id \(esc(id)). Jobs are kept until Synapse restarts.", false)
    case .queued?:
        (title, detail, refresh) = ("Waiting to start", "Another video is rendering first.", true)
    case .in_progress?:
        let minutes = j?.startedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        (title, detail, refresh) = ("Rendering: \(j?.progress ?? 0)%", "Started \(minutes) min ago. This can take up to an hour; the video plays here when it's done.", true)
    case .failed?:
        (title, detail, refresh) = ("Video failed", "<pre>\(esc(String((j?.error ?? "").suffix(1500))))</pre>", false)
    case .completed?:
        (title, detail, refresh) = ("Ready", "", true)
    }
    let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \(refresh ? #"<meta http-equiv="refresh" content="10">"# : "")<title>\(title)</title>
    <style>body{font:16px -apple-system,sans-serif;margin:0;padding:24px 16px;max-width:640px;color:#1d1a26;background:#f7f6fb}
    @media (prefers-color-scheme:dark){body{color:#ece9f5;background:#15131c}}h1{font-size:22px}p,pre{opacity:.75}pre{white-space:pre-wrap;font-size:12px}</style>
    </head><body><h1>\(title)</h1><p>\(esc(j?.prompt ?? ""))</p><p>\(detail)</p></body></html>
    """
    return Response(status: j == nil ? .notFound : .ok, headers: [.contentType: "text/html; charset=utf-8"],
                    body: .init(byteBuffer: ByteBuffer(string: html)))
}
