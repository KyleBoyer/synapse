import Foundation

/// A Python process that keeps one model loaded and answers requests on stdin, one JSON object per line. Replies are
/// stdout lines starting with "SYNAPSE ": first a ready line (or {"fatal"}), then per request any number of lines
/// carrying its "id", ending with one that has "done" or "error". Library logs on stdout are skipped; stderr goes to a
/// log file in the temp folder. Requests run one at a time.
final class PythonSidecar: @unchecked Sendable {
    /// The first line: whatever the script reports once its model is loaded (sample rate, dimensions, ...).
    let ready: [String: Any]
    let logName: String
    private let process: Process
    public var pid: Int32 { process.processIdentifier }
    private let input: FileHandle
    private let lines: LineQueue
    private let serial = AsyncSerial()

    private init(ready: [String: Any], logName: String, process: Process, input: FileHandle, lines: LineQueue) {
        self.ready = ready; self.logName = logName; self.process = process; self.input = input; self.lines = lines
    }

    /// `offline: false` lets a library fetch small companion files into the runtime's own cache on first use;
    /// model weights always come from `folder`.
    static func launch(runtime: PythonRuntime.Spec, script: String, folder: URL, logName: String,
                       offline: Bool = true) async throws -> PythonSidecar {
        let rt = try await PythonRuntime.shared.ensureInstalled(runtime, storeRoot: try PythonRuntime.storeRoot(above: folder))
        let p = Process()
        p.executableURL = rt.python
        p.arguments = ["-c", script, folder.path]
        var env = ["HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
                   "HF_HOME": rt.dir.appending(path: "hf").path, "PYTHONUNBUFFERED": "1"]
        if offline { env["HF_HUB_OFFLINE"] = "1" }
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        let logURL = FileManager.default.temporaryDirectory.appending(path: logName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        let lines = LineQueue()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; lines.close() } else { lines.feed(d) }
        }
        try p.run()
        // Loading can take a minute the first time (Metal kernels, weights from disk, a companion download).
        guard let first = try await lines.next(timeout: 600) else {
            p.terminate()
            let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
            throw EngineError.unsupported("The model's helper process exited while loading: \(tail)")
        }
        if let fatal = first["fatal"] as? String { p.terminate(); throw EngineError.unsupported(fatal) }
        return PythonSidecar(ready: first, logName: logName, process: p, input: stdin.fileHandleForWriting, lines: lines)
    }

    func send(_ obj: [String: Any]) {
        if let line = try? Self.line(obj) { try? input.write(contentsOf: line) }
    }

    /// One request line (JSON plus newline), with `id` added when given.
    static func line(_ obj: [String: Any], id: String? = nil) throws -> Data {
        var o = obj
        if let id { o["id"] = id }
        var line = try JSONSerialization.data(withJSONObject: o)
        line.append(0x0A)
        return line
    }

    /// Sends a request built by `line(_:id:)` and hands each of its replies to `handle` until "done" or "error".
    /// Replies to an earlier, cancelled request are skipped.
    func exchange(_ request: Data, id: String, timeout: Double = 600,
                  handle: @escaping @Sendable ([String: Any]) -> Void) async throws {
        try await serial.run { [self] in
            try input.write(contentsOf: request)
            while true {
                guard let r = try await lines.next(timeout: timeout) else {
                    throw EngineError.unsupported("The model's helper process stopped (see \(logName) in the temp folder).")
                }
                guard r["id"] as? String == id else { continue }
                if let e = r["error"] as? String { throw EngineError.unsupported(e) }
                handle(r)
                if r["done"] as? Bool == true { return }
            }
        }
    }

    func terminate() {
        try? input.close()
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Python every sidecar starts with: exit with Synapse (a child outlives a parent that quits or crashes, and this
    /// one holds a model), and `reply` for "SYNAPSE " lines.
    static let prelude = #"""
import json, os, sys, threading, time, traceback
parent = os.getppid()
def _watch():
    while True:
        time.sleep(1)
        if os.getppid() != parent:
            os._exit(0)
threading.Thread(target=_watch, daemon=True).start()
def reply(obj):
    sys.stdout.write("SYNAPSE " + json.dumps(obj) + "\n")
    sys.stdout.flush()

"""#   // ends with a newline, so a script appended to it starts on its own line
}
