import CoreServices
import Foundation

private final class FSEventsContext: @unchecked Sendable {
    let handler: @Sendable ([String]) -> Void
    init(_ handler: @escaping @Sendable ([String]) -> Void) { self.handler = handler }
}

/// Watches folders (FSEvents + periodic rescan for NAS shares) and submits media files that lack a sidecar.
public actor FolderWatcher {
    public static let mediaExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "webm", "wmv", "flv", "mpg", "mpeg", "vob",
        "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "wma",
    ]
    private static let partialSuffixes = [".part", ".crdownload", ".!qb", ".tmp"]
    private static let junkDirs: Set<String> = ["@eaDir", "#recycle"]

    public static func isCandidate(_ url: URL) -> Bool {
        guard mediaExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let name = url.lastPathComponent.lowercased()
        if partialSuffixes.contains(where: name.hasSuffix) { return false }
        return !url.pathComponents.contains { $0.hasPrefix(".") || junkDirs.contains($0) }
    }

    private let submit: @Sendable (JobRequest) async -> Void
    private let stabilityInterval: Duration
    private let rescanInterval: Duration
    /// Folders keyed by realpath (what FSEvents reports).
    private var folders: [(root: String, folder: WatchFolder)] = []
    private var stream: FSEventStreamRef?
    private var timer: Task<Void, Never>?
    private var pending: Set<String> = []
    private var submittedAt: [String: ContinuousClock.Instant] = [:]
    private var generation = 0
    private let queue = DispatchQueue(label: "synapse.folderwatcher")

    public init(submit: @escaping @Sendable (JobRequest) async -> Void,
                stabilityInterval: Duration = .seconds(5), rescanInterval: Duration = .seconds(600)) {
        self.submit = submit
        self.stabilityInterval = stabilityInterval
        self.rescanInterval = rescanInterval
    }

    public func update(folders newFolders: [WatchFolder], paused: Bool) {
        stop()
        generation += 1
        folders = newFolders.map { (Self.realPath($0.path), $0) }
        guard !paused, !folders.isEmpty else { return }
        startStream()
        let gen = generation
        timer = Task { [weak self, rescanInterval] in
            await self?.rescanAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: rescanInterval)
                if Task.isCancelled { break }
                await self?.rescanAll()
            }
            _ = gen
        }
    }

    public func stop() {
        timer?.cancel(); timer = nil
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        generation += 1 // abandons in-flight stability polls
        pending.removeAll()
    }

    public func rescanAll() async {
        for entry in folders {
            guard let en = FileManager.default.enumerator(
                at: URL(fileURLWithPath: entry.root),
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [URL] = []
            while let url = en.nextObject() as? URL {
                if url.lastPathComponent == "@eaDir" || url.lastPathComponent == "#recycle" { en.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                   Self.isCandidate(url) { found.append(url) }
            }
            for url in found { consider(url, in: entry.folder) }
        }
    }

    private func startStream() {
        let ctx = FSEventsContext { [weak self] paths in
            Task { await self?.handle(paths) }
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(ctx).toOpaque(), retain: nil,
            release: { Unmanaged<FSEventsContext>.fromOpaque($0!).release() }, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let ctx = Unmanaged<FSEventsContext>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            ctx.handler(Array(list.prefix(count)))
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, folders.map(\.root) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func handle(_ paths: [String]) {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            guard Self.isCandidate(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let folder = owner(of: p) else { continue }
            consider(url, in: folder)
        }
    }

    private func owner(of path: String) -> WatchFolder? {
        folders.filter { path == $0.root || path.hasPrefix($0.root + "/") }
            .max { $0.root.count < $1.root.count }?.folder
    }

    private func consider(_ url: URL, in folder: WatchFolder) {
        let path = url.path
        if pending.contains(path) { return }
        if let at = submittedAt[path], ContinuousClock.now - at < rescanInterval { return }
        let lang = folder.task == .translate ? "en" : folder.language
        if Sidecar.existing(for: url, language: lang) != nil { return }
        pending.insert(path)
        let gen = generation
        Task { await self.awaitStable(url, folder, gen) }
    }

    private func awaitStable(_ url: URL, _ folder: WatchFolder, _ gen: Int) async {
        var last: Int?
        while gen == generation {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            guard let size else { break } // vanished
            if size > 0, size == last {
                submittedAt[url.path] = .now
                pending.remove(url.path)
                await submit(JobRequest(input: .media(url), modelID: folder.modelID, language: folder.language,
                                        task: folder.task, writeSidecarNextTo: url, origin: .watcher))
                return
            }
            last = size
            try? await Task.sleep(for: stabilityInterval)
        }
        if gen == generation { pending.remove(url.path) }
    }

    private static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }
}
