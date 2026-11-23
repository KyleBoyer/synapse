import Foundation
import Hummingbird
import HTTPTypes

/// Loopback-only servers need no key. With LAN on, accepts `Authorization: Bearer <key>`, `x-api-key: <key>` (Anthropic SDKs)
/// or a `/k/<key>` path prefix.
struct APIKeyMiddleware: RouterMiddleware {
    let settings: SettingsBox

    func handle(_ request: Request, context: SynapseContext, next: (Request, SynapseContext) async throws -> Response) async throws -> Response {
        let s = settings.current
        guard s.allowLAN else { return try await next(request, context) }
        // A generated file's link (a random UUID name, gone after an hour) or a video's (96 random bits) is its own
        // credential, as OpenAI's signed URLs are: chat apps load markdown images and open links without the key.
        if request.method == .get, Self.isImageFileLink(request.uri.path) { return try await next(request, context) }
        var supplied = context.parameters.get("key")
        if supplied == nil, let h = request.headers[.authorization], h.hasPrefix("Bearer ") {
            supplied = String(h.dropFirst(7))
        }
        if supplied == nil { supplied = request.headers[HTTPField.Name("x-api-key")!] }
        guard let supplied, Self.constantTimeEqual(supplied, s.apiKey) else {
            return apiError(.unauthorized, "Invalid or missing API key.")
        }
        return try await next(request, context)
    }

    static func isImageFileLink(_ path: String) -> Bool {
        path.wholeMatch(of: /(?:\/k\/[^\/]+)?(?:\/v1)*\/images\/files\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:png|jpeg|webp|mp3)/) != nil
            || path.wholeMatch(of: /(?:\/k\/[^\/]+)?(?:\/v1)*\/videos\/video_[0-9a-f]{24}\/content/) != nil
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Turns every thrown error into a JSON body both OpenAI and Anthropic clients parse.
struct ErrorBodyMiddleware: RouterMiddleware {
    func handle(_ request: Request, context: SynapseContext, next: (Request, SynapseContext) async throws -> Response) async throws -> Response {
        do { return try await next(request, context) }
        catch let e as HTTPError { return apiError(e.status, e.body ?? e.status.reasonPhrase) }
        catch let e as ResolveError { return apiError(.badRequest, e.localizedDescription) }
        catch let e as HTTPResponseError { return apiError(e.status, "\(e)") }
        catch { return apiError(.internalServerError, error.localizedDescription) }
    }
}

func apiError(_ status: HTTPResponse.Status, _ message: String) -> Response {
    json(AnyEncodableDict(["type": "error", "error": ["message": message, "type": status.code >= 500 ? "api_error" : "invalid_request_error"]]),
         status: status)
}

func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
}

func text(_ body: String, contentType: String, extra: HTTPFields = [:]) -> Response {
    var headers = extra
    headers[.contentType] = contentType
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: body)))
}
