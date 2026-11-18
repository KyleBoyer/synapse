import Foundation

public enum JobError: Error, LocalizedError {
    case cancelled, diarizerMissing
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Job was cancelled"
        case .diarizerMissing: return "Download Speaker diarization in Models to label speakers."
        }
    }
}

/// The single funnel for all transcription work (GUI, API, watcher).
/// Runs one job at a time; engines are loaded and evicted by the shared ModelManager.
public actor JobQueue {
    public typealias EngineFactory = @Sendable (ModelSpec, URL) async throws -> any TranscriptionEngine
    public typealias DiarizerFactory = @Sendable (URL) async throws -> any SpeakerDiarizing
    static let diarizerID = "speaker-diarizer"

    private let store: ModelStore
    private let decoder: AudioDecoder
    private let settings: SettingsBox
    private let engineFactory: EngineFactory
    private let diarizerFactory: DiarizerFactory
    private let onChange: @Sendable (JobSnapshot) -> Void

    private var jobs: [UUID: JobSnapshot] = [:]
    private var order: [UUID] = []
    private var pending: [UUID] = []
    private var waiters: [UUID: [CheckedContinuation<JobSnapshot, Never>]] = [:]
    private var running: (id: UUID, task: Task<Void, Never>)?
    private let models: ModelManager
    private let keepFinished = 200

    public init(store: ModelStore, decoder: AudioDecoder, settings: SettingsBox,
                models: ModelManager = ModelManager(),
                engineFactory: @escaping EngineFactory = JobQueue.realEngine,
                diarizerFactory: @escaping DiarizerFactory = { try await FluidDiarizer(folder: $0) },
                onChange: @escaping @Sendable (JobSnapshot) -> Void = { _ in }) {
        self.store = store; self.decoder = decoder; self.settings = settings
        self.models = models; self.engineFactory = engineFactory; self.diarizerFactory = diarizerFactory; self.onChange = onChange
    }

    public static let realEngine: EngineFactory = { spec, folder in
        switch spec.engine {
        case .whisper: return try await WhisperEngine(folder: folder)
        case .parakeet: return try await ParakeetEngine(folder: folder, variant: spec.variant)
        case .mlx, .flux2, .zimage, .mflux, .speech, .duplex, .embedding, .reranker, .videogen, .audiogen, .mlxvlm, .gguf, .mlxspeech, .audioedit, .imagetool: throw ResolveError.wrongKind(spec.id)
        }
    }

    // MARK: Public API

    @discardableResult
    public func submit(_ r: JobRequest) -> UUID {
        if r.writeSidecarNextTo != nil, let dup = activeJob(forPath: r.input.url) { return dup }
        let job = JobSnapshot(request: r)
        jobs[job.id] = job
        order.append(job.id)
        onChange(job)
        if let media = r.writeSidecarNextTo, !r.force,
           Sidecar.existing(for: media, language: r.task == .translate ? "en" : r.language) != nil {
            finish(job.id, .skipped("subtitle exists"))
        } else {
            pending.append(job.id)
            pump()
        }
        trim()
        return job.id
    }

    /// Suspends until the job reaches a terminal status.
    public func result(of id: UUID) async -> JobSnapshot? {
        guard let job = jobs[id] else { return nil }
        if job.status.isTerminal { return job }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    public func run(_ r: JobRequest) async -> JobSnapshot {
        let id = submit(r)
        return await result(of: id)!
    }

    public func cancel(_ id: UUID) {
        if let i = pending.firstIndex(of: id) {
            pending.remove(at: i)
            finish(id, .cancelled)
        } else if running?.id == id {
            running?.task.cancel()
        }
    }

    /// Transcribes right away, outside the job list and the queue: a voice-call turn or a voice clip should not wait
    /// behind a long file, nor show up in the Transcribe pane. nil `modelID` uses the default transcription model.
    public func transcribeNow(_ input: AudioInput, modelID: String?, language: String?) async throws -> Transcript {
        let spec = try ModelResolver.resolve(requested: modelID, task: .transcribe, language: language,
                                             defaultID: settings.current.defaultModelID, downloaded: await store.downloaded)
        guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        let dir = try tempDir(UUID())
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try await decoder.decodeToWAV(input, into: dir)
        let lease = try await engineLease(for: spec, folder: folder)
        defer { lease.release() }
        return try await lease.value.transcribe(wav: wav, language: language, task: .transcribe) { _ in }
    }

    public func snapshot(_ id: UUID) -> JobSnapshot? { jobs[id] }
    public func all() -> [JobSnapshot] { order.compactMap { jobs[$0] } }

    public var isBusy: Bool { running != nil }

    /// Uses the smallest downloaded multilingual Whisper model. nil when none is downloaded.
    public func detectLanguage(_ input: AudioInput) async throws -> (code: String, confidence: Double)? {
        guard let spec = ModelResolver.smallestDetector(downloaded: await store.downloaded),
              let folder = await store.folder(for: spec.id) else { return nil }
        // Run through the queue's serial slot so detection never overlaps a transcription.
        while running != nil || !pending.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
        let marker = UUID()
        running = (marker, Task {})
        defer { running = nil; pump() }
        let dir = try tempDir(marker)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try await decoder.decodeToWAV(input, into: dir)
        let lease = try await engineLease(for: spec, folder: folder)
        defer { lease.release() }
        return try await lease.value.detectLanguage(wav: wav)
    }

    // MARK: Internals

    private func activeJob(forPath url: URL) -> UUID? {
        let path = url.standardizedFileURL.path
        return order.first { id in
            guard let j = jobs[id], !j.status.isTerminal else { return false }
            return j.request.input.url.standardizedFileURL.path == path
        }
    }

    private func pump() {
        guard running == nil, !pending.isEmpty else { return }
        let id = pending.removeFirst()
        let task = Task { await self.execute(id) }
        running = (id, task)
    }

    private func execute(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        let r = job.request
        let dir: URL
        do { dir = try tempDir(id) } catch { return complete(id, .failed(error.localizedDescription)) }
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let downloaded = await store.downloaded
            let s = settings.current
            let spec = try ModelResolver.resolve(requested: r.modelID, task: r.task, language: r.language,
                                                 defaultID: s.defaultModelID, downloaded: downloaded)
            guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
            update(id) { $0.modelID = spec.id; $0.status = .decoding }
            let wav = try await decoder.decodeToWAV(r.input, into: dir)
            try Task.checkCancellation()

            if await !models.isLoaded(spec.id) { update(id) { $0.status = .preparingModel } }
            let lease = try await engineLease(for: spec, folder: folder)
            defer { lease.release() }
            let engine = lease.value
            try Task.checkCancellation()
            update(id) { $0.status = .transcribing(nil) }

            var transcript = try await engine.transcribe(wav: wav, language: r.language, task: r.task) { p in
                Task { await self.progress(id, p) }
            }
            try Task.checkCancellation()
            if r.diarize {
                update(id) { $0.status = .diarizing }
                transcript = SpeakerAssigner.assign(transcript, turns: try await diarize(wav))
                try Task.checkCancellation()
            }

            var output: URL?
            if let media = r.writeSidecarNextTo {
                let lang = transcript.language ?? r.language
                let url = Sidecar.url(for: media, language: lang)
                let srt = Subtitles.srt(Subtitles.makeCues(transcript, s.cue))
                try Data(srt.utf8).write(to: url, options: .atomic)
                output = url
            }
            update(id) { $0.transcript = transcript; $0.outputURL = output }
            complete(id, .done)
        } catch is CancellationError {
            complete(id, .cancelled)
        } catch {
            complete(id, Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
        }
    }

    private func diarize(_ wav: URL) async throws -> [SpeakerTurn] {
        guard let folder = await store.folder(for: Self.diarizerID), let spec = Catalog.spec(Self.diarizerID) else {
            throw JobError.diarizerMissing
        }
        let factory = diarizerFactory
        let lease = try await models.lease(Self.diarizerID, as: (any SpeakerDiarizing).self, estimatedBytes: spec.estimatedBytes) {
            (try await factory(folder), unload: {})
        }
        defer { lease.release() }
        return try await lease.value.diarize(wav: wav)
    }

    private func engineLease(for spec: ModelSpec, folder: URL) async throws -> ModelLease<any TranscriptionEngine> {
        let factory = engineFactory
        return try await models.lease(spec.id, as: (any TranscriptionEngine).self, estimatedBytes: spec.estimatedBytes) {
            let engine = try await factory(spec, folder)
            return (engine, unload: { await engine.unload() })
        }
    }

    private func progress(_ id: UUID, _ p: Double?) {
        guard let j = jobs[id], case .transcribing = j.status else { return }
        update(id) { $0.status = .transcribing(p) }
    }

    private func complete(_ id: UUID, _ status: JobStatus) {
        running = nil
        finish(id, status)
        pump()
    }

    private func finish(_ id: UUID, _ status: JobStatus) {
        update(id) { $0.status = status }
        guard let job = jobs[id] else { return }
        waiters.removeValue(forKey: id)?.forEach { $0.resume(returning: job) }
    }

    private func update(_ id: UUID, _ change: (inout JobSnapshot) -> Void) {
        guard var j = jobs[id] else { return }
        change(&j)
        jobs[id] = j
        onChange(j)
    }

    private func trim() {
        let finished = order.filter { jobs[$0]?.status.isTerminal == true }
        guard finished.count > keepFinished else { return }
        let drop = Set(finished.prefix(finished.count - keepFinished))
        order.removeAll { drop.contains($0) }
        drop.forEach { jobs[$0] = nil }
    }

    private func tempDir(_ id: UUID) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse/\(id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
