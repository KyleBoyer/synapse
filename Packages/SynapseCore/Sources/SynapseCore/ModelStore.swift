import Foundation
@preconcurrency import WhisperKit
@preconcurrency import FluidAudio

/// Owns model files on disk. The manifest is written only after a download fully succeeds,
/// so a crash mid-download leaves the model "not downloaded" rather than half-ready.
public actor ModelStore {
    public let root: URL
    private var manifest: [String: String] = [:]   // modelID -> folder path relative to root
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var progressByID: [String: Double] = [:]
    private var failures: [String: String] = [:]

    public init(root: URL = ModelStore.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appending(path: "manifest.json")),
           let m = try? JSONDecoder().decode([String: String].self, from: data) {
            manifest = m.filter { FileManager.default.fileExists(atPath: root.appending(path: $0.value).path) }
        }
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Synapse/Models", directoryHint: .isDirectory)
    }

    /// WhisperKit's pick for this Mac's chip.
    public static var recommendedWhisperVariant: String { WhisperKit.recommendedModels().default }

    public func folder(for id: String) -> URL? {
        manifest[id].map { root.appending(path: $0, directoryHint: .isDirectory) }
    }

    public var downloaded: Set<String> { Set(manifest.keys) }

    public func states() -> [String: ModelState] {
        var out: [String: ModelState] = [:]
        for spec in Catalog.all {
            if let f = folder(for: spec.id) { out[spec.id] = .ready(f) }
            else if let p = progressByID[spec.id] { out[spec.id] = .downloading(p) }
            else if let e = failures[spec.id] { out[spec.id] = .failed(e) }
            else { out[spec.id] = .notDownloaded }
        }
        return out
    }

    /// Concurrent calls for the same id share one download.
    public func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let f = folder(for: id) { return f }
        if let t = inFlight[id] { return try await t.value }
        guard let spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
        let root = root
        failures[id] = nil
        progressByID[id] = 0
        let task = Task<URL, Error> {
            try await Self.fetch(spec, root: root) { p in
                progress(p)
                Task { await self.setProgress(id, p) }
            }
        }
        inFlight[id] = task
        defer { inFlight[id] = nil; progressByID[id] = nil }
        do {
            let url = try await task.value
            let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            manifest[id] = rel
            try saveManifest()
            return url
        } catch {
            failures[id] = error is CancellationError ? nil : error.localizedDescription
            try? FileManager.default.removeItem(at: Self.partialFolder(spec, root: root))
            throw error
        }
    }

    public func cancelDownload(_ id: String) { inFlight[id]?.cancel() }

    public func delete(_ id: String) throws {
        guard let f = folder(for: id) else { return }
        try FileManager.default.removeItem(at: f)
        manifest[id] = nil
        try saveManifest()
    }

    private func setProgress(_ id: String, _ p: Double) {
        if inFlight[id] != nil { progressByID[id] = p }
    }

    private func saveManifest() throws {
        try JSONEncoder().encode(manifest).write(to: root.appending(path: "manifest.json"), options: .atomic)
    }

    private static func parakeetFolder(_ spec: ModelSpec, root: URL) -> URL {
        let name = AsrModels.defaultCacheDirectory(for: ParakeetEngine.version(spec.variant)).lastPathComponent
        return root.appending(path: "parakeet/\(name)", directoryHint: .isDirectory)
    }

    private static func mlxFolder(_ spec: ModelSpec, root: URL) -> URL {
        root.appending(path: "mlx/\(spec.variant)", directoryHint: .isDirectory)
    }

    private static func partialFolder(_ spec: ModelSpec, root: URL) -> URL {
        switch spec.engine {
        case .mlx: return mlxFolder(spec, root: root)
        case .parakeet: return parakeetFolder(spec, root: root)
        case .whisper:
            let prefix = spec.variant.hasPrefix("distil") ? "distil-whisper_" : "openai_whisper-"
            return root.appending(path: "whisperkit/models/argmaxinc/whisperkit-coreml/\(prefix)\(spec.variant)")
        }
    }

    private static func fetch(_ spec: ModelSpec, root: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        switch spec.engine {
        case .whisper:
            return try await WhisperKit.download(
                variant: spec.variant,
                downloadBase: root.appending(path: "whisperkit", directoryHint: .isDirectory),
                progressCallback: { progress($0.fractionCompleted) })
        case .mlx:
            return try await HFDownloader.download(repo: spec.variant, to: mlxFolder(spec, root: root), progress: progress)
        case .parakeet:
            let dir = parakeetFolder(spec, root: root)
            return try await AsrModels.download(
                to: dir, version: ParakeetEngine.version(spec.variant),
                progressHandler: { progress($0.fractionCompleted) })
        }
    }
}
