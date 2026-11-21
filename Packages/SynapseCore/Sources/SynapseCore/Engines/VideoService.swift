import Foundation

public enum VideoError: Error, LocalizedError {
    case noModel, notDownloaded(String), unknownModel(String), wrongAddOn(String, base: String)
    public var errorDescription: String? {
        switch self {
        case .noModel: "No video model is downloaded. Download LTX-2.3 Distilled in Models."
        case .notDownloaded(let id): "Model '\(id)' is not downloaded."
        case .unknownModel(let id): "Model '\(id)' is not a video model."
        case .wrongAddOn(let id, let base): "'\(id)' is not a LoRA for '\(base)'."
        }
    }
}

public struct VideoJob: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case queued, in_progress, completed, failed }
    public let id: String
    public var model: String
    public var prompt: String
    public var request: VideoRequest
    public var status: Status = .queued
    /// 0...100
    public var progress: Int = 0
    public var createdAt = Date()
    public var startedAt: Date?
    public var completedAt: Date?
    public var error: String?
    public var file: URL?
    /// The size the client asked for; the generated size is rounded down to multiples of 64 (see `request`).
    public var size: String

    public var seconds: Int { (request.frames - 1) / request.fps }
}

/// OpenAI Videos-style jobs: a FIFO queue, one generation at a time, files under `<models>/videos`.
// shortcut: jobs live in memory and do not survive a restart; files older than a day are deleted at startup.
public actor VideoService {
    public typealias EngineFactory = @Sendable (ModelSpec, URL) async throws -> any VideoEngine
    private let store: ModelStore
    private let models: ModelManager
    private let engineFactory: EngineFactory
    private let directory: URL
    private var jobs: [VideoJob] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var watchers: [UUID: AsyncStream<VideoJob>.Continuation] = [:]

    public init(store: ModelStore, models: ModelManager, engineFactory: @escaping EngineFactory = VideoEngines.real) {
        self.store = store; self.models = models; self.engineFactory = engineFactory
        directory = store.root.appending(path: "videos", directoryHint: .isDirectory)
        let cutoff = Date().addingTimeInterval(-86_400)
        for f in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// nil and OpenAI's names (sora-2, sora-2-pro) mean the first downloaded video model.
    public func resolve(_ requested: String?) async throws -> ModelSpec {
        let videoSpecs = Catalog.all.filter(\.isVideoGen)
        let available: (ModelSpec) async -> Bool = { VideoEngines.mock ? true : await self.store.folder(for: $0.id) != nil }
        if let id = requested, !["", "sora-2", "sora-2-pro"].contains(id) {
            guard let spec = Catalog.spec(id) else { throw VideoError.unknownModel(id) }
            guard spec.isVideoGen else { throw VideoError.unknownModel(id) }
            guard await available(spec) else { throw VideoError.notDownloaded(id) }
            return spec
        }
        for spec in videoSpecs where await available(spec) { return spec }
        throw VideoError.noModel
    }

    /// The weights file of LoRA add-on `id`, which must patch `base` and be downloaded.
    public func addOnFile(_ id: String, for base: ModelSpec) async throws -> URL {
        guard let addOn = Catalog.spec(id), addOn.baseModel == base.id, let file = addOn.files?.first else {
            throw VideoError.wrongAddOn(id, base: base.id)
        }
        guard let folder = await store.folder(for: id) else { throw VideoError.notDownloaded(id) }
        return folder.appending(path: file)
    }

    /// LTX frame counts are 8k+1; at 24 fps, 4 s is 97 frames.
    public static func frames(seconds: Int, fps: Int = 24) -> Int { seconds * fps + 1 }

    public func create(model: ModelSpec, request: VideoRequest, size: String? = nil) -> VideoJob {
        let id = "video_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        let job = VideoJob(id: id, model: model.id, prompt: request.prompt, request: request,
                           size: size ?? "\(request.width)x\(request.height)")
        jobs.append(job)
        publish(job)
        pump()
        return job
    }

    public func job(_ id: String) -> VideoJob? { jobs.first { $0.id == id } }
    /// Newest first.
    public func all() -> [VideoJob] { jobs.reversed() }

    /// Cancels the job if it is running and removes its file.
    public func delete(_ id: String) -> Bool {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return false }
        tasks[id]?.cancel(); tasks[id] = nil
        if let f = jobs[i].file { try? FileManager.default.removeItem(at: f) }
        jobs.remove(at: i)
        pump()
        return true
    }

    /// Every change to any job, for the app.
    public func updates() -> AsyncStream<VideoJob> {
        let (stream, cont) = AsyncStream<VideoJob>.makeStream()
        let key = UUID()
        watchers[key] = cont
        cont.onTermination = { _ in Task { await self.unwatch(key) } }
        return stream
    }

    private func unwatch(_ key: UUID) { watchers[key] = nil }
    private func publish(_ job: VideoJob) { for c in watchers.values { c.yield(job) } }

    private func update(_ id: String, _ change: (inout VideoJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        publish(jobs[i])
    }

    /// Starts the oldest queued job when nothing is running.
    private func pump() {
        guard !jobs.contains(where: { $0.status == .in_progress }),
              let next = jobs.first(where: { $0.status == .queued }) else { return }
        update(next.id) { $0.status = .in_progress; $0.startedAt = Date() }
        tasks[next.id] = Task { await self.run(next) }
    }

    private func run(_ job: VideoJob) async {
        let output = directory.appending(path: "\(job.id).mp4")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let spec = Catalog.spec(job.model) else { throw VideoError.unknownModel(job.model) }
            let folder = await store.folder(for: spec.id) ?? FileManager.default.temporaryDirectory
            let engine = try await engineFactory(spec, folder)
            var patched = job.request
            if let lora = patched.lora { patched.loraFile = try await addOnFile(lora, for: spec) }
            let id = job.id, request = patched
            let generate: @Sendable () async throws -> Void = {
                try await GPUGate.shared.run {
                    try await engine.generate(request, to: output) { p in
                        Task { await self.update(id) { $0.progress = max($0.progress, min(99, Int(p * 100))) } }
                    }
                }
            }
            // The generator is a separate process MLX cannot see, so its memory is reserved for the run only.
            // The mock uses none.
            if VideoEngines.mock { try await generate() } else {
                try await models.reserve(spec.id, estimatedBytes: spec.estimatedResidentBytes, during: generate)
            }
            try Task.checkCancellation()
            update(job.id) { $0.status = .completed; $0.progress = 100; $0.completedAt = Date(); $0.file = output }
        } catch {
            try? FileManager.default.removeItem(at: output)
            update(job.id) { $0.status = .failed; $0.completedAt = Date(); $0.error = error.localizedDescription }
        }
        tasks[job.id] = nil
        pump()
    }
}
