import Foundation
import Observation
import SynapseCore

@MainActor @Observable
final class AppState {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            if settings.customModels != oldValue.customModels { Catalog.setCustom(settings.customModels) }
            settingsBox.current = settings
            settings.save()
            applySettings(old: oldValue)
        }
    }
    var modelStates: [String: ModelState] = [:]
    var jobs: [JobSnapshot] = []
    var serverStatus: ServerController.Status = .stopped
    var startupError: String?
    var residents: [ResidentInfo] = []
    var memoryOvercommitted = false
    /// Settings is a sheet over the main window, opened from ⌘, the menu bar extra, or in-app links.
    var showingSettings = false
    /// Panes doing work right now; the sidebar marks them with the live dot.
    var activePanes: Set<Pane> = []
    func isActive(_ pane: Pane) -> Bool {
        pane == .transcribe ? jobs.contains { !$0.status.isTerminal } : activePanes.contains(pane)
    }
    func setActive(_ pane: Pane, _ on: Bool) { if on { activePanes.insert(pane) } else { activePanes.remove(pane) } }
    /// When each job left the queue, and how long it took once finished.
    private(set) var jobStarted: [UUID: Date] = [:]
    private(set) var jobElapsed: [UUID: Double] = [:]
    let metrics = MetricsStore()

    let settingsBox: SettingsBox
    let store: ModelStore
    let models: ModelManager
    let queue: JobQueue
    let chat: ChatService
    let images: ImageService
    let realtime: RealtimeServices
    let speech: SpeechService
    let embeddings: EmbeddingService
    let videos: VideoService
    let sound: SoundService
    let server: ServerController
    let watcher: FolderWatcher

    init() {
        let s = Settings.load()
        settings = s
        settingsBox = SettingsBox(s)
        store = ModelStore(root: s.modelsRoot)
        models = ModelManager.forApp(config: s.modelManagerConfig)
        let decoder = AudioDecoder.bundled() ?? AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"))
        if AudioDecoder.bundled() == nil { startupError = "Bundled ffmpeg is missing; decoding will fail." }

        let (updates, sink) = AsyncStream.makeStream(of: JobSnapshot.self)
        queue = JobQueue(store: store, decoder: decoder, settings: settingsBox, models: models, onChange: { sink.yield($0) })
        let queue = queue
        chat = ChatService(store: store, models: models)
        images = ImageService(store: store, models: models, engineFactory: ImageEngines.real)
        realtime = .real(store: store, models: models, chat: chat)
        speech = SpeechService(store: store, models: models)
        embeddings = EmbeddingService(store: store, models: models)
        videos = VideoService(store: store, models: models)
        sound = SoundService(store: store, models: models)
        server = ServerController(queue: queue, store: store, settings: settingsBox, chat: chat, images: images, realtime: realtime,
                                  speech: speech, embeddings: embeddings, videos: videos, sound: sound)
        watcher = FolderWatcher(submit: { _ = await queue.submit($0) })
        Task { [weak self] in
            for await snap in updates { self?.upsert(snap) }
        }
        Catalog.setCustom(s.customModels)
        Task { await refreshModels() }
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshResidents()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        applySettings(old: nil)
    }

    func resident(_ id: String) -> ResidentInfo? { residents.first { $0.id == id } }

    // MARK: Jobs

    private func upsert(_ snap: JobSnapshot) {
        if snap.status != .queued, jobStarted[snap.id] == nil { jobStarted[snap.id] = Date() }
        if snap.status == .done, jobElapsed[snap.id] == nil, let start = jobStarted[snap.id] {
            let elapsed = Date().timeIntervalSince(start)
            jobElapsed[snap.id] = elapsed
            // Diarized runs include speaker labeling, so they are not a transcription speed measurement.
            if let model = snap.modelID, let t = snap.transcript, t.duration > 0, !snap.request.diarize {
                metrics.record(model, .realtimeSpeed, t.duration / elapsed)
            }
        }
        if let i = jobs.firstIndex(where: { $0.id == snap.id }) { jobs[i] = snap } else { jobs.append(snap) }
        if jobs.count > 300 { jobs.removeFirst(jobs.count - 300) }
    }

    func submit(files: [URL], modelID: String?, language: String?, task: TaskKind, saveSidecar: Bool, diarize: Bool = false) {
        let media = files.flatMap(Self.expand)
        Task {
            for url in media {
                await queue.submit(JobRequest(input: .media(url), modelID: modelID, language: language, task: task,
                                              writeSidecarNextTo: saveSidecar ? url : nil, force: true, origin: .gui, diarize: diarize))
            }
        }
    }

    func cancel(_ id: UUID) { Task { await queue.cancel(id) } }

    func clearFinished() { jobs.removeAll { $0.status.isTerminal } }

    /// Folders expand to the media files inside them.
    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (e?.allObjects as? [URL] ?? []).filter(FolderWatcher.isCandidate).sorted { $0.path < $1.path }
    }

    // MARK: Models

    private var readySpecs: [ModelSpec] {
        Catalog.all.filter { if case .ready = modelStates[$0.id] { return true }; return false }
    }
    var downloadedSpecs: [ModelSpec] { readySpecs.filter(\.isTranscription) }
    var downloadedImageSpecs: [ModelSpec] { readySpecs.filter(\.isImage) }
    var downloadedTTSSpecs: [ModelSpec] { readySpecs.filter(\.isTTS) }
    var downloadedEmbeddingSpecs: [ModelSpec] { readySpecs.filter(\.isEmbedding) }
    var downloadedRerankerSpecs: [ModelSpec] { readySpecs.filter(\.isReranker) }
    var downloadedVideoSpecs: [ModelSpec] { readySpecs.filter(\.isVideoGen) }
    var downloadedSoundSpecs: [ModelSpec] { SoundEngines.mock ? Catalog.all.filter(\.isAudioGen) : readySpecs.filter(\.isAudioGen) }
    var diarizerReady: Bool { if case .ready = modelStates["speaker-diarizer"] { return true }; return false }
    var downloadedRealtimeBase: Bool { ["parakeet-eou-120m", "silero-vad", "pocket-tts"].allSatisfy { if case .ready = modelStates[$0] { return true }; return false } }
    var downloadedDuplexSpecs: [ModelSpec] { readySpecs.filter { $0.engine == .duplex } }
    var downloadedChatSpecs: [ModelSpec] { readySpecs.filter { $0.isChat } }

    func refreshResidents() async {
        residents = await models.residents()
        memoryOvercommitted = await models.overcommitted
    }
    func unloadModel(_ id: String) { Task { await models.unload(id); await refreshResidents() } }
    func unloadAllIdle() { Task { await models.unloadAllIdle(); await refreshResidents() } }

    func refreshModels() async { modelStates = await store.states() }

    func download(_ id: String) {
        modelStates[id] = .downloading(0)
        Task {
            do {
                _ = try await store.download(id, token: settings.hfToken ?? HFDownloader.cliToken()) { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.modelStates[id] { self?.modelStates[id] = .downloading(p) }
                    }
                }
            } catch {}
            await refreshModels()
        }
    }

    func cancelDownload(_ id: String) { Task { await store.cancelDownload(id) } }

    /// Adds a model found on Hugging Face to the list (it downloads like any catalog model).
    func addCustom(_ model: CustomModel) {
        guard !settings.customModels.contains(where: { $0.repo == model.repo }) else { return }
        settings.customModels.append(model)
        Task { await refreshModels() }
    }

    /// Takes an added model off the list, deleting its files first if it was downloaded.
    func removeCustom(_ id: String) {
        Task {
            if case .ready = modelStates[id] {
                guard await models.unload(id) else { modelStates[id] = .failed("Model is in use by a running job"); return }
                try? await store.delete(id)
            }
            settings.customModels.removeAll { $0.repo == id }
            await refreshModels()
        }
    }

    func delete(_ id: String) {
        Task {
            guard await models.unload(id) else {
                modelStates[id] = .failed("Model is in use by a running job")
                return
            }
            do { try await store.delete(id) } catch { modelStates[id] = .failed(error.localizedDescription) }
            await refreshModels()
        }
    }

    // MARK: Server & watcher

    private func applySettings(old: Settings?) {
        let s = settings
        let serverChanged = old == nil || old?.serverEnabled != s.serverEnabled || old?.port != s.port || old?.allowLAN != s.allowLAN
        if serverChanged {
            Task {
                await server.stop()
                if s.serverEnabled { await server.start() }
                serverStatus = await server.status
            }
        }
        if old?.memoryBudgetGB != s.memoryBudgetGB || old?.idleUnloadMinutes != s.idleUnloadMinutes {
            let config = s.modelManagerConfig
            Task { await models.update(config: config) }
        }
        if old == nil || old?.watchFolders != s.watchFolders || old?.watchingPaused != s.watchingPaused {
            Task { await watcher.update(folders: s.watchFolders, paused: s.watchingPaused) }
        }
    }

    func refreshServerStatus() async { serverStatus = await server.status }
}
