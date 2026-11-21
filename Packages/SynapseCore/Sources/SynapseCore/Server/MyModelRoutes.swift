import Foundation
import Hummingbird
import NIOCore
import Synchronization

/// The user's own models (Settings.customModels, "Added from Hugging Face"). The app owns that list and installs
/// the handlers; until it does, the routes answer 503. Used by the `synapse` command-line tool.
public final class MyModels: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var repo: String
        public var engine: String
        /// A LoRA's base model.
        public var base: String?
        public var files: [String]
        public var sizeMB: Int
        /// "downloaded", "not downloaded", "downloading 42%", or "failed: <reason>".
        public var state: String

        public init(_ m: CustomModel, state: ModelState) {
            id = m.id; name = m.displayName; repo = m.repo; engine = m.engine.rawValue; base = m.baseModel
            files = m.files ?? []; sizeMB = m.approxMB
            self.state = switch state {
            case .ready: "downloaded"
            case .notDownloaded: "not downloaded"
            case .downloading(let p): "downloading \(Int(p * 100))%"
            case .failed(let why): "failed: \(why)"
            }
        }
    }

    public struct Handlers: Sendable {
        public var list: @Sendable () async -> [Entry]
        /// Adds the model to the list and, when asked, starts its download (it continues after the reply).
        public var add: @Sendable (CustomModel, _ download: Bool) async throws -> Void
        /// Takes the model off the list, deleting its files if downloaded.
        public var remove: @Sendable (String) async throws -> Void

        public init(list: @escaping @Sendable () async -> [Entry], add: @escaping @Sendable (CustomModel, Bool) async throws -> Void,
                    remove: @escaping @Sendable (String) async throws -> Void) {
            self.list = list; self.add = add; self.remove = remove
        }
    }

    private let handlers = Mutex<Handlers?>(nil)
    public init() {}
    public func install(_ h: Handlers) { handlers.withLock { $0 = h } }
    var current: Handlers? { handlers.withLock { $0 } }
}

/// Changing the model list (and deleting files) is for this Mac only, even when the server is open to the LAN.
struct LoopbackOnlyMiddleware: RouterMiddleware {
    func handle(_ request: Request, context: SynapseContext, next: (Request, SynapseContext) async throws -> Response) async throws -> Response {
        let ip = context.remoteAddress?.ipAddress ?? ""
        let local = ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
        guard local else { return apiError(.forbidden, "Managing models is only allowed from this Mac.") }
        return try await next(request, context)
    }
}

private struct AddBody: Decodable {
    var repo: String
    /// A file or quantization label to pick instead of the default.
    var file: String?
    var download: Bool?
}

private struct Added: Encodable {
    var model: MyModels.Entry
    var notes: [String]
    var choices: [String]
}

func addMyModelRoutes(to g: RouterGroup<SynapseContext>, models: MyModels, settings: SettingsBox) {
    let mine = g.group("synapse/models").add(middleware: LoopbackOnlyMiddleware())
    let unavailable = apiError(.serviceUnavailable, "The Synapse app is still starting.")
    mine.get { _, _ in
        guard let h = models.current else { return unavailable }
        return json(["data": await h.list()])
    }
    mine.post { req, ctx in
        guard let h = models.current else { return unavailable }
        let body = try await req.decode(as: AddBody.self, context: ctx)
        var report: HFModelInspector.Report
        do {
            report = try await HFModelInspector.inspect(body.repo, token: settings.current.hfToken ?? HFDownloader.cliToken())
        } catch {
            return apiError(.badRequest, error.localizedDescription)
        }
        let choices = report.ggufChoices
        if let want = body.file {
            guard let c = choices.first(where: { $0.label.caseInsensitiveCompare(want) == .orderedSame || $0.files.contains(want) }) else {
                return apiError(.badRequest, "\(body.repo) has no file '\(want)'. Choices: \(choices.map(\.label).joined(separator: ", "))")
            }
            report = report.choosing(c)
        }
        let m = report.model
        guard await !h.list().contains(where: { $0.id == m.id }) else { return apiError(.conflict, "\(m.id) is already in your list.") }
        if let base = m.baseModel, Catalog.spec(base) == nil { return apiError(.badRequest, "\(m.id) needs \(base), which is not available.") }
        try await h.add(m, body.download ?? true)
        let entry = await h.list().first { $0.id == m.id } ?? MyModels.Entry(m, state: .notDownloaded)
        return json(Added(model: entry, notes: report.notes, choices: choices.map(\.label)), status: .created)
    }
    mine.delete("**") { _, ctx in
        guard let h = models.current else { return unavailable }
        let joined = ctx.parameters.getCatchAll().joined(separator: "/")
        let id = joined.removingPercentEncoding ?? joined
        guard await h.list().contains(where: { $0.id == id }) else { return apiError(.notFound, "\(id) is not in your list.") }
        do { try await h.remove(id) } catch { return apiError(.conflict, error.localizedDescription) }
        return json(["deleted": id])
    }
}
