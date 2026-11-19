import Foundation

/// One running llama.cpp `llama-server` for a GGUF model, on 127.0.0.1 and a free port. It speaks the same
/// OpenAI chat API as mlx-vlm's server, so MLXVLMChat builds its requests and reads its stream.
public final class LlamaServer: @unchecked Sendable {
    let base: URL
    let modelPath: String
    private let process: Process
    public var pid: Int32 { process.processIdentifier }
    private let logURL: URL

    private init(base: URL, modelPath: String, process: Process, logURL: URL) {
        self.base = base; self.modelPath = modelPath; self.process = process; self.logURL = logURL
    }

    /// The bundled binary; SYNAPSE_LLAMA_SERVER or the repo's vendor build when running from source (tests).
    static func binary() -> URL? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "llama-server") { return u }
        if let p = ProcessInfo.processInfo.environment["SYNAPSE_LLAMA_SERVER"] { return URL(fileURLWithPath: p) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../../vendor/llama.cpp/bin/llama-server")
        return FileManager.default.isExecutableFile(atPath: repo.standardizedFileURL.path) ? repo.standardizedFileURL : nil
    }

    /// Exits with the parent (a child outlives a parent that quits or crashes, and this one holds a whole model):
    /// a shell starts the server, then polls the parent and stops the server when it is gone or when asked to.
    static let watchdog = #"""
        parent=$1; shift
        "$@" & child=$!
        trap 'kill $child 2>/dev/null; wait $child; exit 0' TERM INT
        while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done
        kill $child 2>/dev/null; wait $child
        """#

    static func launch(folder: URL, files: [String]) async throws -> LlamaServer {
        guard let exe = binary() else { throw EngineError.unsupported("llama-server is missing from this build (run scripts/build-llama.sh).") }
        guard let weights = files.first(where: { !$0.lowercased().contains("mmproj") }) else {
            throw EngineError.unsupported("No GGUF weights file was chosen for this model.")
        }
        let port = try MLXVLMServer.freePort()
        var args = ["-m", folder.appending(path: weights).path, "--host", "127.0.0.1", "--port", String(port),
                    "--fit", "on", "--jinja", "--offline", "--no-ui", "-np", "1"]
        if let projector = files.first(where: { $0.lowercased().contains("mmproj") }) {
            args += ["--mmproj", folder.appending(path: projector).path]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", watchdog, "sh", String(ProcessInfo.processInfo.processIdentifier), exe.path] + args
        let logURL = FileManager.default.temporaryDirectory.appending(path: "synapse-llama-\(port).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        p.standardOutput = log; p.standardError = log; p.standardInput = FileHandle.nullDevice
        try p.run()
        let server = LlamaServer(base: URL(string: "http://127.0.0.1:\(port)")!, modelPath: weights, process: p, logURL: logURL)
        do { try await server.waitUntilReady() } catch { server.terminate(); throw error }
        return server
    }

    /// /health answers 503 while the model loads and 200 once it can serve.
    private func waitUntilReady(timeout: Duration = .seconds(600)) async throws {
        let deadline = ContinuousClock.now + timeout
        let req = URLRequest(url: base.appending(path: "health"), timeoutInterval: 2)
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(800)) } ?? ""
                throw EngineError.unsupported("llama-server exited while loading the model: \(tail)")
            }
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EngineError.unsupported("llama-server did not become ready within \(timeout); log: \(logURL.path)")
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()   // the watchdog's trap stops the server and waits for it
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
