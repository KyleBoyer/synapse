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
    let updates = UpdateCenter()
    /// "Try in <pane>" from Models: the pane selects this model when it appears, then clears it.
    struct TryRequest: Equatable { let pane: Pane; let modelID: String }
    var tryRequest: TryRequest?
    /// The requested model if it is meant for `pane`; taking it clears the request.
    func takeTry(_ pane: Pane) -> ModelSpec? {
        guard let r = tryRequest, r.pane == pane else { return nil }
        tryRequest = nil
        return Catalog.spec(r.modelID)
    }
    /// A result sent on to another pane as the next step's input (an image to animate, a clip to transform…).
    /// MainView switches to the target pane, which takes the handoff (when it appears, or at once if already open).
    enum Handoff: Equatable {
        /// Images → Generate, as the reference for an edit.
        case editImage(Data)
        /// Video → Generate, as the clip's start image.
        case animateImage(Data)
        /// Video → Transform, as the input clip.
        case transformVideo(URL)
        /// Audio → Clean Up, as the input recording (a video's soundtrack works too).
        case cleanUp(URL)
        /// Transcribe, as a dropped file.
        case transcribe(URL)
        /// Chat's composer: text to send and attachments.
        case chat(text: String, images: [Data], videos: [URL], audios: [URL])
        /// Text as the prompt of another generation, left in its composer to edit before running.
        case prompt(String, PromptTarget)
        enum PromptTarget: Equatable { case image, video, speech, sound }

        var pane: Pane {
            switch self {
            case .editImage, .prompt(_, .image): .images
            case .animateImage, .transformVideo, .prompt(_, .video): .video
            case .cleanUp, .prompt(_, .speech), .prompt(_, .sound): .audio
            case .transcribe: .transcribe
            case .chat: .chat
            }
        }
    }
    var handoff: Handoff?
    /// The pane a handoff goes to; kept apart from `handoff`, which a pane already open takes at once.
    var paneRequest: Pane?
    func send(_ h: Handoff) { handoff = h; paneRequest = h.pane }

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
    /// Work done in the panes, kept across launches. Only GUI code saves here; API requests never do.
    let history = HistoryStore(root: HistoryStore.defaultRoot)
    /// Bumped on every save and delete, so panes showing history reload.
    private(set) var historyRevision = 0
    /// Video jobs started from the Video pane; only these are saved to history (the service also runs API jobs).
    var guiVideoJobs = Set<String>()
    @ObservationIgnored private var lastPrune = Date()

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
        chat = ChatService(store: store, models: models, promptCacheBytes: s.promptCacheBytes, diskCacheBytes: s.diskCacheBytes)
        images = ImageService(store: store, models: models, engineFactory: ImageEngines.real)
        realtime = .real(store: store, models: models, chat: chat, transcribe: RealtimeServices.turnTranscriber(queue))
        speech = SpeechService(store: store, models: models, transcribe: SpeechService.transcriber(queue))
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
            // Only files dropped in Transcribe: API jobs never go to history, and watched folders write their own files.
            if snap.request.origin == .gui, let t = snap.transcript, case .media(let url) = snap.request.input {
                let record = TranscriptRecord(source: url.path, task: snap.request.task.rawValue, transcript: t)
                saveHistory(HistoryItem(id: snap.id, kind: .transcript, title: url.lastPathComponent, model: snap.modelID ?? "",
                                        payload: (try? JSONEncoder().encode(record)) ?? Data()))
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
    /// Downloaded LoRA add-ons that patch `base`.
    func downloadedAddOns(for base: String) -> [ModelSpec] { readySpecs.filter { $0.baseModel == base } }
    var downloadedEditSpecs: [ModelSpec] { readySpecs.filter(\.isAudioEdit) }
    var downloadedImageToolSpecs: [ModelSpec] { readySpecs.filter { $0.engine == .imagetool } }
    var downloadedSoundSpecs: [ModelSpec] { SoundEngines.mock ? Catalog.all.filter(\.isAudioGen) : readySpecs.filter(\.isAudioGen) }
    var diarizerReady: Bool { if case .ready = modelStates["speaker-diarizer"] { return true }; return false }
    func isReady(_ id: String) -> Bool { if case .ready = modelStates[id] { return true }; return false }
    var downloadedRealtimeBase: Bool { ["parakeet-eou-120m", "silero-vad", "pocket-tts"].allSatisfy { if case .ready = modelStates[$0] { return true }; return false } }
    var downloadedDuplexSpecs: [ModelSpec] { readySpecs.filter { $0.engine == .duplex && DuplexEngines.conversational.contains($0.id) } }
    var downloadedChatSpecs: [ModelSpec] { readySpecs.filter { $0.isChat } }

    func refreshResidents() async {
        residents = await models.residents()
        memoryOvercommitted = await models.overcommitted
        cacheStats = await chat.cacheStats()
        diskCache = chat.diskCacheUsage()
        // The server reports running from its own callback, after start() returns, so the status is re-read here.
        serverStatus = await server.status
        if Date().timeIntervalSince(lastPrune) > 3600 { lastPrune = Date(); pruneHistory() }
    }

    /// Prompt-cache counters per chat model since launch, every request included (refreshed with the residents).
    private(set) var cacheStats: [String: PromptCacheStats] = [:]
    private(set) var diskCache: (bytes: Int, entries: Int) = (0, 0)

    // MARK: History

    var savesHistory: Bool { settings.historyDays != 0 }

    /// Saves an item unless history is off. `copy` names files to copy in (videos), by their name in the item.
    func saveHistory(_ item: HistoryItem, files: [String: Data] = [:], copy: [String: URL] = [:]) {
        guard savesHistory else { return }
        var item = item
        item.files = Array(Set(item.files).union(copy.keys))
        let history = history
        Task {
            do {
                for (name, url) in copy { try await history.addFile(item, name: name, copying: url) }
                try await history.save(item, files: files)
            } catch {
                startupError = "Could not save to history: \(error.localizedDescription)"
            }
            historyRevision += 1
        }
    }

    func deleteHistory(_ ids: [UUID], kind: HistoryKind) {
        Task { await history.delete(ids, kind: kind); historyRevision += 1 }
    }

    func clearHistory(_ kind: HistoryKind?) {
        Task { await history.deleteAll(kind); historyRevision += 1 }
    }

    private func pruneHistory() {
        let cutoff = settings.historyDays.flatMap { $0 > 0 ? Date().addingTimeInterval(-Double($0) * 86_400) : nil }
        Task { await history.prune(olderThan: cutoff); historyRevision += 1 }
    }

    /// Loads keep-warm models one at a time, so each finishes before the next takes memory.
    func preload(_ ids: [String]) {
        let chat = chat, images = images
        Task {
            for id in ids {
                guard let spec = Catalog.spec(id), await store.folder(for: id) != nil else { continue }
                // A model that fails to load here is retried, with its error shown, on first real use.
                if spec.isChat { try? await chat.preload(spec) } else if spec.isImage { try? await images.preload(spec) }
                await refreshResidents()
            }
        }
    }

    func clearPromptCache(_ id: String?, disk: Bool) { Task { await chat.clearCache(id, disk: disk); await refreshResidents() } }
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
        guard !settings.customModels.contains(where: { $0.id == model.id }) else { return }
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
            settings.customModels.removeAll { $0.id == id }
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
        if old?.memoryBudgetGB != s.memoryBudgetGB || old?.idleUnloadMinutes != s.idleUnloadMinutes || old?.keepWarm != s.keepWarm {
            let config = s.modelManagerConfig
            Task { await models.update(config: config) }
        }
        // Launch loads every keep-warm model; later, only the ones just added.
        let added = s.keepWarm.filter { !(old?.keepWarm ?? []).contains($0) }
        if !added.isEmpty { preload(added) }
        if let old, old.promptCacheGB != s.promptCacheGB { let b = s.promptCacheBytes; Task { await chat.setPromptCacheLimit(b) } }
        if let old, old.diskCacheGB != s.diskCacheGB { let b = s.diskCacheBytes; Task { await chat.setDiskCacheLimit(b) } }
        if old?.kvPrecision != s.kvPrecision { let p = s.kvPrecision; Task { await chat.setKVPrecision(p) } }
        if old == nil || old?.historyDays != s.historyDays { pruneHistory() }
        if old?.draftModels != s.draftModels {
            let ids = Set(s.draftModels.keys).union(old?.draftModels.keys ?? [:].keys)
            let drafts = s.draftModels
            Task { for id in ids { await chat.setDraftModel(drafts[id], for: id) } }
        }
        if old == nil || old?.watchFolders != s.watchFolders || old?.watchingPaused != s.watchingPaused {
            Task { await watcher.update(folders: s.watchFolders, paused: s.watchingPaused) }
        }
    }

    func refreshServerStatus() async { serverStatus = await server.status }
}

/// A saved transcript: the text with its timing, and where the audio was (the file itself is not copied).
struct TranscriptRecord: Codable {
    var source: String
    var task: String
    var transcript: Transcript

    /// As a finished job, so the transcript sheet shows it like any other.
    func job(_ item: HistoryItem) -> JobSnapshot {
        JobSnapshot(id: item.id, request: JobRequest(input: .media(URL(fileURLWithPath: source)), modelID: item.model,
                                                    task: TaskKind(rawValue: task) ?? .transcribe, origin: .gui),
                    status: .done, modelID: item.model, transcript: transcript)
    }
}
