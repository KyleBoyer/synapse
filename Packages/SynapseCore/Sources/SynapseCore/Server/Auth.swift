import Foundation
import Hummingbird

/// Loopback-only servers need no key. With LAN on, accepts `Authorization: Bearer <key>` or a `/k/<key>` path prefix.
struct APIKeyMiddleware: RouterMiddleware {
    let settings: SettingsBox

    func handle(_ request: Request, context: SynapseContext, next: (Request, SynapseContext) async throws -> Response) async throws -> Response {
        let s = settings.current
        guard s.allowLAN else { return try await next(request, context) }
        var supplied = context.parameters.get("key")
        if supplied == nil, let h = request.headers[.authorization], h.hasPrefix("Bearer ") {
            supplied = String(h.dropFirst(7))
        }
        guard let supplied, Self.constantTimeEqual(supplied, s.apiKey) else {
            return apiError(.unauthorized, "Invalid or missing API key.")
        }
        return try await next(request, context)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Turns every thrown error into an OpenAI-style JSON body.
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
    json(["error": ["message": message, "type": "invalid_request_error"]], status: status)
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
