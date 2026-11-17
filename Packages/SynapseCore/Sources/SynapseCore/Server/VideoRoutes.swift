import Foundation
import Hummingbird

/// OpenAI Videos API (`openai.types.Video`): create, poll, download, list, delete.
func addVideoRoutes(to g: RouterGroup<SynapseContext>, videos: VideoService) {
    g.post("videos") { req, ctx in
        let fields: [String: String], image: Data?
        if req.headers[.contentType]?.hasPrefix("multipart/form-data") == true {
            let form = try await parseMultipart(req, ctx, fileFields: ["input_reference"])
            fields = form.fields; image = form.files.first?.data
        } else {
            let raw = try await rawBody(req, ctx)
            guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw HTTPError(.badRequest, message: "Body must be a JSON object or multipart form.")
            }
            fields = o.compactMapValues { v in (v as? String) ?? (v as? NSNumber).map { "\($0)" } }
            image = nil
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
        do { spec = try await videos.resolve(nonEmpty(fields["model"])) } catch { throw HTTPError(.badRequest, message: error.localizedDescription) }
        let job = await videos.create(model: spec, request: VideoRequest(
            prompt: prompt, width: width, height: height, frames: VideoService.frames(seconds: s),
            seed: fields["seed"].flatMap { UInt64($0) }, inputImage: image), size: sizeText)
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
        let j = try await job(ctx, videos)
        guard j.status == .completed, let file = j.file else { throw HTTPError(.notFound, message: "Video is not ready.") }
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
