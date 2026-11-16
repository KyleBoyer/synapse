import Foundation
import HTTPTypes
import Hummingbird
import ImageIO
import MultipartKit
import NIOCore
import UniformTypeIdentifiers

// OpenAI Images API: POST /v1/images/generations, POST /v1/images/edits, GET /v1/images/files/:name.

struct ImageParams: Decodable {
    var prompt: String?
    var model: String?
    var n: Int?
    var size: String?
    var quality: String?
    var output_format: String?
    var output_compression: Int?
    var response_format: String?
    var stream: Bool?
    var partial_images: Int?
    var steps: Int?
    var seed: UInt64?
    var guidance: Float?
    var negative_prompt: String?

    init(form f: [String: String]) {
        prompt = f["prompt"]; model = f["model"]; n = f["n"].flatMap { Int($0) }; size = f["size"]; quality = f["quality"]
        output_format = f["output_format"]; output_compression = f["output_compression"].flatMap { Int($0) }
        response_format = f["response_format"]; stream = f["stream"].map { $0.lowercased() == "true" }
        partial_images = f["partial_images"].flatMap { Int($0) }; steps = f["steps"].flatMap { Int($0) }
        seed = f["seed"].flatMap { UInt64($0) }; guidance = f["guidance"].flatMap { Float($0) }; negative_prompt = f["negative_prompt"]
    }
}

/// In-memory store behind `response_format=url`: 64 entries, 1 hour.
actor ImageFileCache {
    private var entries: [String: (data: Data, mime: String, expires: Date, added: Date)] = [:]
    func put(_ data: Data, ext: String, mime: String) -> String {
        let now = Date()
        entries = entries.filter { $0.value.expires > now }
        while entries.count >= 64, let oldest = entries.min(by: { $0.value.added < $1.value.added })?.key { entries[oldest] = nil }
        let name = "\(UUID().uuidString.lowercased()).\(ext)"
        entries[name] = (data, mime, now.addingTimeInterval(3600), now)
        return name
    }
    func get(_ name: String) -> (data: Data, mime: String)? {
        guard let e = entries[name], e.expires > Date() else { entries[name] = nil; return nil }
        return (e.data, e.mime)
    }
}

private struct ImageUsage: Encodable {
    struct Details: Encodable { var image_tokens = 0, text_tokens = 0 }
    var input_tokens = 0, output_tokens = 0, total_tokens = 0
    var input_tokens_details = Details()
}

private struct ImageItem: Encodable { var b64_json: String?; var url: String? }

private struct ImagesResponse: Encodable {
    var created: Int
    var data: [ImageItem]
    var output_format: String, size: String, quality: String
    var background = "opaque"
    var usage = ImageUsage()
}

private struct ImageEvent: Encodable {
    var type: String
    var b64_json: String
    var partial_image_index: Int?
    var background = "opaque"
    var created_at: Int
    var output_format: String, quality: String, size: String
    var usage: ImageUsage?
}

enum ImageEncoding {
    static func supportsWebP() -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.webP.identifier)
    }

    static func encode(_ png: Data, format: String, compression: Int?) throws -> Data {
        guard format != "png" else { return png }
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw HTTPError(.internalServerError, message: "Engine returned an undecodable image.")
        }
        let out = NSMutableData()
        let type = format == "jpeg" ? UTType.jpeg : UTType.webP
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw HTTPError(.internalServerError, message: "Could not encode \(format).")
        }
        let q = Double(min(100, max(0, compression ?? 100))) / 100
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw HTTPError(.internalServerError, message: "Could not encode \(format).") }
        return out as Data
    }
}

/// Picks up to `count` previews spread across the steps.
private final class PreviewPicker: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = 0
    let count: Int
    init(count: Int) { self.count = count }
    func pick(_ p: ImageProgress) -> Data? {
        guard let preview = p.preview, p.step < p.totalSteps else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard emitted < count, p.step >= max(1, (emitted + 1) * p.totalSteps / (count + 1)) else { return nil }
        emitted += 1
        return preview
    }
}

private func badRequest(_ m: String) -> HTTPError { HTTPError(.badRequest, message: m) }

func mapImageError(_ e: Error) -> Error {
    guard let e = e as? ImageError else { return e }
    return HTTPError(e == .noImageModel ? .serviceUnavailable : .badRequest, message: e.localizedDescription)
}

/// Splits multipart/form-data into text fields and file parts (repeated `image[]` keys stay in order).
private func parseMultipart(_ req: Request, _ ctx: SynapseContext) async throws -> (fields: [String: String], files: [(name: String, data: Data)]) {
    guard let ct = req.headers[.contentType], let media = MediaType(from: ct), media.parameter?.name == "boundary",
          let boundary = media.parameter?.value else { throw HTTPError(.unsupportedMediaType) }
    let buffer = try await req.body.collect(upTo: ctx.maxUploadSize)
    let parser = MultipartParser(boundary: boundary)
    var parts: [MultipartPart] = []
    var headers = HTTPHeaders(), body = ByteBuffer()
    parser.onHeader = { headers.replaceOrAdd(name: $0, value: $1) }
    parser.onBody = { body.writeBuffer(&$0) }
    parser.onPartComplete = { parts.append(MultipartPart(headers: headers, body: body)); headers = .init(); body = ByteBuffer() }
    do { try parser.execute(buffer) } catch { throw badRequest("Invalid multipart body: \(error)") }
    var fields: [String: String] = [:], files: [(String, Data)] = []
    for p in parts {
        guard let name = p.name else { continue }
        if ["image", "image[]", "mask"].contains(name) { files.append((name, Data(buffer: p.body))) }
        else { fields[name] = String(buffer: p.body) }
    }
    return (fields, files)
}

func addImageRoutes(to g: RouterGroup<SynapseContext>, images: ImageService, files cache: ImageFileCache,
                    chat: ChatService, settings: SettingsBox) {
    g.post("v1/images/generations") { req, ctx in
        let raw = try await rawBody(req, ctx)
        if let proxied = try await proxyToVOOM(raw, path: "v1/images/generations", chat: chat, settings: settings) { return proxied }
        let p = try decodeJSON(ImageParams.self, raw)
        return try await runImages(p, images: images, cache: cache, req: req, ctx: ctx, inputs: [], mask: nil, edit: false)
    }
    g.post("v1/images/edits") { req, ctx in
        let (fields, files) = try await parseMultipart(req, ctx)
        let inputs = files.filter { $0.name != "mask" }.map(\.data)
        guard !inputs.isEmpty else { throw badRequest("image is required.") }
        return try await runImages(ImageParams(form: fields), images: images, cache: cache, req: req, ctx: ctx,
                                   inputs: inputs, mask: files.first { $0.name == "mask" }?.data, edit: true)
    }
    g.get("v1/images/files/:name") { _, ctx in
        guard let name = ctx.parameters.get("name"), let f = await cache.get(name) else {
            throw HTTPError(.notFound, message: "Image not found or expired.")
        }
        return Response(status: .ok, headers: [.contentType: f.mime, .cacheControl: "private, max-age=3600"],
                        body: .init(byteBuffer: ByteBuffer(data: f.data)))
    }
}

private func runImages(_ p: ImageParams, images: ImageService, cache: ImageFileCache, req: Request, ctx: SynapseContext,
                       inputs: [Data], mask: Data?, edit: Bool) async throws -> Response {
    guard let prompt = nonEmpty(p.prompt) else { throw badRequest("prompt is required.") }
    let n = p.n ?? 1
    guard (1...4).contains(n) else { throw badRequest("n must be between 1 and 4.") }
    let format = nonEmpty(p.output_format) ?? "png"
    guard ["png", "jpeg", "webp"].contains(format) else { throw badRequest("Unsupported output_format '\(format)'.") }
    if format == "webp" && !ImageEncoding.supportsWebP() { throw badRequest("webp output is not supported on this system") }
    if let c = p.output_compression, !(0...100).contains(c) { throw badRequest("output_compression must be between 0 and 100.") }
    let responseFormat = nonEmpty(p.response_format) ?? "b64_json"
    guard ["b64_json", "url"].contains(responseFormat) else { throw badRequest("Unsupported response_format '\(responseFormat)'.") }
    let requestedQuality = nonEmpty(p.quality) ?? "auto"
    guard ["low", "medium", "high", "auto", "standard", "hd"].contains(requestedQuality) else { throw badRequest("Unsupported quality '\(requestedQuality)'.") }
    let quality = ["auto": "medium", "standard": "medium", "hd": "high"][requestedQuality] ?? requestedQuality
    let partial = p.partial_images ?? 0
    guard (0...3).contains(partial) else { throw badRequest("partial_images must be between 0 and 3.") }

    let spec: ModelSpec, w: Int, h: Int
    do {
        (w, h) = try ImageService.parseSize(p.size)
        spec = try await images.resolve(nonEmpty(p.model), edit: edit)
    } catch { throw mapImageError(error) }
    let size = "\(w)x\(h)"
    let request = ImageRequest(prompt: prompt, negativePrompt: nonEmpty(p.negative_prompt), width: w, height: h, steps: p.steps,
                               guidance: p.guidance, seed: p.seed, inputImages: inputs, mask: mask)
    do { try request.validate() } catch { throw mapImageError(error) }
    let created = Int(Date().timeIntervalSince1970)
    let prefix = edit ? "image_edit" : "image_generation"
    let compression = p.output_compression
    let mime = ["png": "image/png", "jpeg": "image/jpeg", "webp": "image/webp"][format]!

    @Sendable func generateOne(_ i: Int, onPreview: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> Data {
        var r = request
        if let s = request.seed { r.seed = s &+ UInt64(i) }
        let picker = PreviewPicker(count: partial)
        do {
            return try await images.generate(model: spec, request: r) { _, prog in
                if let pv = picker.pick(prog) { onPreview(pv) }
            }[0]
        } catch { throw mapImageError(error) }
    }

    guard p.stream == true else {
        var items: [ImageItem] = []
        let host = req.headers[HTTPField.Name("Host")!] ?? req.head.authority ?? "localhost"
        let keyPrefix = ctx.parameters.get("key").map { "k/\($0)/" } ?? ""
        for i in 0..<n {
            let data = try ImageEncoding.encode(try await generateOne(i), format: format, compression: compression)
            if responseFormat == "url" {
                let name = await cache.put(data, ext: format, mime: mime)
                items.append(ImageItem(url: "http://\(host)/\(keyPrefix)v1/images/files/\(name)"))
            } else {
                items.append(ImageItem(b64_json: data.base64EncodedString()))
            }
        }
        return json(ImagesResponse(created: created, data: items, output_format: format, size: size, quality: quality))
    }

    return sse { write in
        for i in 0..<n {
            let (previews, sink) = AsyncStream.makeStream(of: Data.self)
            let gen = Task {
                defer { sink.finish() }
                return try await generateOne(i) { sink.yield($0) }
            }
            let png = try await withTaskCancellationHandler {
                var index = 0
                for await pv in previews {
                    let b64 = try ImageEncoding.encode(pv, format: format, compression: compression).base64EncodedString()
                    try await write("\(prefix).partial_image", ImageEvent(type: "\(prefix).partial_image", b64_json: b64, partial_image_index: index,
                                                                          created_at: created, output_format: format, quality: quality, size: size))
                    index += 1
                }
                return try await gen.value
            } onCancel: { gen.cancel() }
            let b64 = try ImageEncoding.encode(png, format: format, compression: compression).base64EncodedString()
            try await write("\(prefix).completed", ImageEvent(type: "\(prefix).completed", b64_json: b64, created_at: created, output_format: format,
                                                              quality: quality, size: size, usage: ImageUsage()))
        }
    }
}
