import Foundation
import Observation
import SynapseCore

@MainActor @Observable
final class AppState {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settingsBox.current = settings
            settings.save()
            applySettings(old: oldValue)
        }
    }
    var modelStates: [String: ModelState] = [:]
    var jobs: [JobSnapshot] = []
    var serverStatus: ServerController.Status = .stopped
    var startupError: String?

    let settingsBox: SettingsBox
    let store: ModelStore
    let queue: JobQueue
    let chat: ChatService
    let server: ServerController
    let watcher: FolderWatcher

    init() {
        let s = Settings.load()
        settings = s
        settingsBox = SettingsBox(s)
        store = ModelStore()
        let decoder = AudioDecoder.bundled() ?? AudioDecoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"))
        if AudioDecoder.bundled() == nil { startupError = "Bundled ffmpeg is missing; decoding will fail." }

        let (updates, sink) = AsyncStream.makeStream(of: JobSnapshot.self)
        queue = JobQueue(store: store, decoder: decoder, settings: settingsBox, onChange: { sink.yield($0) })
        let queue = queue
        chat = ChatService(store: store)
        server = ServerController(queue: queue, store: store, settings: settingsBox, chat: chat)
        watcher = FolderWatcher(submit: { _ = await queue.submit($0) })
        Task { [weak self] in
            for await snap in updates { self?.upsert(snap) }
        }
        Task { await refreshModels() }
        applySettings(old: nil)
    }

    // MARK: Jobs

    private func upsert(_ snap: JobSnapshot) {
        if let i = jobs.firstIndex(where: { $0.id == snap.id }) { jobs[i] = snap } else { jobs.append(snap) }
        if jobs.count > 300 { jobs.removeFirst(jobs.count - 300) }
    }

    func submit(files: [URL], modelID: String?, language: String?, task: TaskKind, saveSidecar: Bool) {
        let media = files.flatMap(Self.expand)
        Task {
            for url in media {
                await queue.submit(JobRequest(input: .media(url), modelID: modelID, language: language, task: task,
                                              writeSidecarNextTo: saveSidecar ? url : nil, force: true, origin: .gui))
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
    var downloadedSpecs: [ModelSpec] { readySpecs.filter { !$0.isChat } }
    var downloadedChatSpecs: [ModelSpec] { readySpecs.filter { $0.isChat } }

    func refreshModels() async { modelStates = await store.states() }

    func download(_ id: String) {
        modelStates[id] = .downloading(0)
        Task {
            do {
                _ = try await store.download(id) { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.modelStates[id] { self?.modelStates[id] = .downloading(p) }
                    }
                }
            } catch {}
            await refreshModels()
        }
    }

    func cancelDownload(_ id: String) { Task { await store.cancelDownload(id) } }

    func delete(_ id: String) {
        let isChat = Catalog.all.first { $0.id == id }?.isChat ?? false
        Task {
            if isChat { await chat.unload(ifModel: id) }
            guard await queue.unload(ifModel: id) else {
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
        if old == nil || old?.watchFolders != s.watchFolders || old?.watchingPaused != s.watchingPaused {
            Task { await watcher.update(folders: s.watchFolders, paused: s.watchingPaused) }
        }
    }

    func refreshServerStatus() async { serverStatus = await server.status }
}
