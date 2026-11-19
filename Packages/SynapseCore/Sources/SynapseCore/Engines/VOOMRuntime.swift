import Foundation

/// Optional "optimized runtime": the user's vOOM checkout (a Python MLX server that pages weights from SSD so
/// models larger than memory run). Synapse launches it on demand and proxies `voom:<model>` requests to it.
///
/// vOOM assumes it owns the GPU (it caps Metal around 8.5 GB), so its process is registered with the
/// ModelManager as one large resident: loading it evicts Synapse's idle models, and the idle reaper stops it.
public actor VOOMRuntime {
    public static let modelPrefix = "voom:"
    static let residentID = "voom-runtime"
    static let estimatedBytes = 9 * 1_073_741_824

    public let checkout: URL
    public let port: Int
    /// Synapse's models folder; vOOM scans it for image models it can page.
    let modelsRoot: URL?
    private let models: ModelManager
    nonisolated(unsafe) private static var instances: [String: VOOMRuntime] = [:]
    private static let lock = NSLock()

    init(checkout: URL, port: Int, modelsRoot: URL?, models: ModelManager) {
        self.checkout = checkout; self.port = port; self.modelsRoot = modelsRoot; self.models = models
    }

    /// One runtime per checkout and models folder, shared by all requests.
    public static func shared(checkout: String, port: Int = 8077, modelsRoot: URL? = nil, models: ModelManager) -> VOOMRuntime {
        lock.withLock {
            let key = checkout + "|" + (modelsRoot?.path ?? "")
            if let r = instances[key] { return r }
            let r = VOOMRuntime(checkout: URL(fileURLWithPath: checkout, isDirectory: true), port: port,
                                modelsRoot: modelsRoot, models: models)
            instances[key] = r
            return r
        }
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Diffusers pipeline classes vOOM's paged image runtime implements (runtime/image_gen.py PIPELINES).
    static let imagePipelines: Set<String> = ["ZImagePipeline"]

    /// Models vOOM can serve, as `voom:<name>` ids: its own `models/` folder, plus image models in Synapse's
    /// models folder (`mlx/<org>/<model>`) whose pipeline vOOM pages.
    public static func modelIDs(checkout: String, modelsRoot: URL? = nil) -> [String] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: checkout, isDirectory: true).appending(path: "models", directoryHint: .isDirectory)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var ids = names.filter { !$0.hasPrefix(".") && fm.fileExists(atPath: dir.appending(path: "\($0)/config.json").path) }
        if let mlx = modelsRoot?.appending(path: "mlx", directoryHint: .isDirectory) {
            for org in (try? fm.contentsOfDirectory(at: mlx, includingPropertiesForKeys: nil)) ?? [] {
                for model in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [] {
                    guard let data = try? Data(contentsOf: model.appending(path: "model_index.json")),
                          let index = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let cls = index["_class_name"] as? String, imagePipelines.contains(cls) else { continue }
                    ids.append(model.lastPathComponent)
                }
            }
        }
        return Set(ids).sorted().map { Self.modelPrefix + $0 }
    }

    /// Ensures the server is up and returns a lease that keeps it resident for the request.
    public func lease() async throws -> ModelLease<VOOMProcess> {
        let checkout = checkout, port = port, base = baseURL, modelsRoot = modelsRoot
        return try await models.lease(Self.residentID, as: VOOMProcess.self, estimatedBytes: Self.estimatedBytes,
                                      measure: { ProcessMemory.footprint(tree: $0.pid) }) {
            let process = try VOOMProcess.launch(checkout: checkout, port: port,
                                                 imageModelDirs: modelsRoot.map { $0.appending(path: "mlx").path })
            do { try await process.waitUntilReady(base: base) } catch { process.terminate(); throw error }
            return (process, unload: { process.terminate() })
        }
    }
}

/// The vOOM server subprocess.
public final class VOOMProcess: @unchecked Sendable {
    private let process: Process
    public var pid: Int32 { process.processIdentifier }
    private let log: FileHandle?

    private init(process: Process, log: FileHandle?) { self.process = process; self.log = log }

    static func launch(checkout: URL, port: Int, imageModelDirs: String?) throws -> VOOMProcess {
        let python = checkout.appending(path: ".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineError.unsupported("vOOM checkout at \(checkout.path) has no .venv/bin/python")
        }
        if isListening(port: port) {
            throw EngineError.unsupported("Port \(port) is already in use; stop the other vOOM server first.")
        }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "runtime.server", "--port", String(port)]
        p.currentDirectoryURL = checkout
        if let imageModelDirs {
            p.environment = ProcessInfo.processInfo.environment.merging(["VMODEL_IMAGE_MODEL_DIRS": imageModelDirs]) { $1 }
        }
        let logURL = FileManager.default.temporaryDirectory.appending(path: "synapse-voom-\(port).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        return VOOMProcess(process: p, log: log)
    }

    func waitUntilReady(base: URL, timeout: Duration = .seconds(180)) async throws {
        let deadline = ContinuousClock.now + timeout
        var req = URLRequest(url: base.appending(path: "v1/models"), timeoutInterval: 2)
        req.httpMethod = "GET"
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                throw EngineError.unsupported("vOOM exited during startup (code \(process.terminationStatus)); see \(FileManager.default.temporaryDirectory.path)/synapse-voom-*.log")
            }
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EngineError.unsupported("vOOM did not become ready within \(timeout)")
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? log?.close()
    }

    private static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
