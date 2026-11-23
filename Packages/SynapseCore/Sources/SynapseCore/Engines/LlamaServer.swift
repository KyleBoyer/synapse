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

    /// A bundled llama.cpp tool (llama-server, llama-quantize); for llama-server SYNAPSE_LLAMA_SERVER, or the repo's
    /// vendor build when running from source (tests).
    static func binary(_ name: String = "llama-server") -> URL? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: name) { return u }
        if name == "llama-server", let p = ProcessInfo.processInfo.environment["SYNAPSE_LLAMA_SERVER"] { return URL(fileURLWithPath: p) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../../vendor/llama.cpp/bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: repo.standardizedFileURL.path) ? repo.standardizedFileURL : nil
    }

    /// Exits with the parent (a child outlives a parent that quits or crashes, and this one holds a whole model):
    /// a shell starts the server, then polls the parent and stops the server when it is gone or when asked to.
    /// llama-server can hang in Metal teardown after SIGTERM, keeping the model's memory, so after 5 s it is killed;
    /// otherwise `terminate()` kills only this shell and the next model loads beside an orphaned one.
    static let watchdog = #"""
        parent=$1; shift
        "$@" & child=$!
        stop() {
            kill $child 2>/dev/null
            for i in 1 2 3 4 5; do kill -0 $child 2>/dev/null || exit 0; sleep 1; done
            kill -9 $child 2>/dev/null; exit 0
        }
        trap stop TERM INT
        while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done
        stop
        """#

    /// `cacheMiB` caps llama.cpp's host-memory prompt cache (its own default is 8 GiB), matching Synapse's setting.
    /// `lora` is a LoRA GGUF applied to the weights at full strength.
    static func launch(folder: URL, files: [String], lora: URL? = nil, cacheMiB: Int, kv: KVPrecision = .full) async throws -> LlamaServer {
        guard let exe = binary() else { throw EngineError.unsupported("llama-server is missing from this build (run scripts/build-llama.sh).") }
        guard let weights = files.first(where: { !$0.lowercased().contains("mmproj") }) else {
            throw EngineError.unsupported("No GGUF weights file was chosen for this model.")
        }
        let port = try MLXVLMServer.freePort()
        var args = ["-m", folder.appending(path: weights).path, "--host", "127.0.0.1", "--port", String(port),
                    "--fit", "on", "--jinja", "--offline", "--no-ui", "-np", "1",
                    "--cache-ram", String(cacheMiB)] + kv.llamaArgs
        if let projector = files.first(where: { $0.lowercased().contains("mmproj") }) {
            args += ["--mmproj", folder.appending(path: projector).path]
        }
        if let lora { args += ["--lora", lora.path] }
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
