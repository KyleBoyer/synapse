import Foundation
import os

/// Qwen-Image family through a managed Python `mflux` sidecar (no Swift port exists).
/// One sidecar process per engine; requests are serialized; the model stays loaded until `unload()`.
public actor MFluxImageEngine: ImageEngine {
    private static let log = Logger(subsystem: "synapse", category: "mflux")

    private let spec: ModelSpec
    private let folder: URL
    private var sidecar: MFluxSidecar?
    private var nextID = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(spec: ModelSpec, folder: URL) async throws {
        self.spec = spec; self.folder = folder
        guard FileManager.default.fileExists(atPath: folder.appending(path: "transformer").path) else {
            throw MFluxError.runtime("\(spec.displayName) snapshot not readable at \(folder.path)")
        }
        sidecar = try await startSidecar()
    }

    private var is21: Bool { spec.id.contains("2.1") }
    private var kind: String {
        if spec.canEditImages { return spec.id.contains("2511") ? "qwen-edit-2511" : "qwen-edit" }
        return is21 ? "qwen-2.1" : "qwen-image"
    }

    private func startSidecar() async throws -> MFluxSidecar {
        let rt = try await MFluxRuntime.shared.ensureInstalled(for: folder)
        let s = try MFluxSidecar(python: rt.python, script: rt.script, extraEnv: rt.env)
        do {
            try await s.waitReady()
            _ = try await s.request(op: "load", ["id": nextRequestID(), "kind": kind, "model_path": folder.path])
        } catch { s.terminate(); throw error }
        return s
    }

    private func nextRequestID() -> Int { nextID += 1; return nextID }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func generate(_ request: ImageRequest, progress: @escaping @Sendable (ImageProgress) -> Void) async throws -> Data {
        if request.isEdit && !spec.canEditImages { throw ImageError.editUnsupported(spec.id) }
        if request.mask != nil { throw ImageError.invalidRequest("Masks are not supported by \(spec.displayName).") }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if sidecar == nil || sidecar?.isRunning == false {
            sidecar?.terminate()
            sidecar = nil
            sidecar = try await startSidecar()  // the next request after a crash relaunches and reloads
        }
        guard let s = sidecar else { throw MFluxError.sidecar("sidecar unavailable") }
        var body: [String: Any] = [
            "id": nextRequestID(), "prompt": request.prompt,
            "width": request.width, "height": request.height,
            // 2.1 base: 40 steps, no CFG (mflux docs); 2512 / Edit: 20 steps, guidance 4.
            "steps": request.steps ?? (is21 ? 40 : 20),
            "guidance": Double(request.guidance ?? (is21 ? 1.0 : 4.0)),
            "seed": request.seed ?? UInt64.random(in: 0..<UInt64(UInt32.max)),
        ]
        if let n = request.negativePrompt, !n.isEmpty { body["negative_prompt"] = n }
        if request.isEdit { body["images"] = request.inputImages.map { $0.base64EncodedString() } }
        do {
            let ev = try await s.request(op: request.isEdit ? "edit" : "generate", body, onProgress: { step, total in
                progress(ImageProgress(step: step, totalSteps: total))
            }, cancelOnTaskCancel: true)
            guard let b64 = ev["png_b64"] as? String, let png = Data(base64Encoded: b64) else {
                throw MFluxError.sidecar("sidecar returned no image.")
            }
            return png
        } catch let e as MFluxError {
            if !s.isRunning { sidecar = nil }
            throw e
        }
    }

    public func unload() async {
        guard let s = sidecar else { return }
        sidecar = nil
        await s.shutdown()
    }
}

/// A running Python sidecar speaking JSON lines. Requests are issued one at a time by the engine.
final class MFluxSidecar: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stderrTail = MFluxBuffer()
    private let lock = NSLock()
    private let events: EventBox
    private var exited = false

    init(python: URL, script: URL, extraEnv: [String: String]) throws {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PYTHON") }
        env.merge(extraEnv) { _, new in new }
        process.executableURL = python
        process.arguments = ["-I", script.path]  // -I: ignore user site/PYTHON* env
        process.environment = env
        process.standardInput = stdin
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err

        var continuation: AsyncStream<MFluxEvent>.Continuation!
        let stream = AsyncStream<MFluxEvent> { continuation = $0 }
        events = EventBox(stream.makeAsyncIterator())
        let cont = continuation!
        let lines = MFluxBuffer(keepAll: true)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; cont.finish(); return }
            for line in lines.appendLines(d) {
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { cont.yield(MFluxEvent(obj)) }
            }
        }
        let tail = stderrTail
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            tail.append(d)
            FileHandle.standardError.write(d)  // mflux logs; keeps the pipe drained
        }
        process.terminationHandler = { [weak self] _ in
            self?.lock.lock(); self?.exited = true; self?.lock.unlock()
        }
        try process.run()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !exited && process.isRunning }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
    }

    private func died() -> MFluxError {
        let tail = String(decoding: stderrTail.data, as: UTF8.self).suffix(500)
        return .sidecar("the sidecar process exited unexpectedly. \(tail)")
    }

    func waitReady() async throws {
        while let ev = await events.next() { if ev["event"] as? String == "ready" { return } }
        throw died()
    }

    /// Sends one request and waits for its terminal event. The wait is not tied to the caller's cancellation
    /// (so the sidecar's final event is always consumed); cancelling the caller sends `cancel` instead.
    @discardableResult
    func request(op: String, _ body: [String: Any], onProgress: (@Sendable (Int, Int) -> Void)? = nil,
                 cancelOnTaskCancel: Bool = false) async throws -> MFluxEvent {
        let id = body["id"] as? Int ?? -1
        var msg = body; msg["op"] = op
        send(msg)
        let work = Task<MFluxEvent, Error> { [self, events] in
            while let ev = await events.next() {
                guard (ev["id"] as? Int) == id else { continue }
                switch ev["event"] as? String {
                case "progress": onProgress?(ev["step"] as? Int ?? 0, ev["total"] as? Int ?? 0)
                case "error":
                    if ev["cancelled"] as? Bool == true { throw CancellationError() }
                    throw MFluxError.sidecar(ev["message"] as? String ?? "unknown error")
                default: return ev
                }
            }
            throw died()
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: {
            if cancelOnTaskCancel { self.send(["op": "cancel"]) }
        }
    }

    func shutdown() async {
        send(["id": -2, "op": "shutdown"])
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        terminate()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
    }
}

/// Single-consumer holder for the event iterator (requests are serialized by the engine).
final class EventBox: @unchecked Sendable {
    private var it: AsyncStream<MFluxEvent>.Iterator
    init(_ it: AsyncStream<MFluxEvent>.Iterator) { self.it = it }
    func next() async -> MFluxEvent? { await it.next() }
}

/// A decoded sidecar JSON event (read-only after creation).
struct MFluxEvent: @unchecked Sendable {
    let dict: [String: Any]
    init(_ d: [String: Any]) { dict = d }
    subscript(key: String) -> Any? { dict[key] }
}

/// Thread-safe byte buffer. Default keeps only the last 16 KB (stderr tail); `keepAll` is used for line splitting.
final class MFluxBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let keepAll: Bool
    init(keepAll: Bool = false) { self.keepAll = keepAll }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(d)
        if !keepAll && storage.count > 16_384 { storage = storage.suffix(16_384) }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    /// Appends and returns the complete newline-terminated lines.
    func appendLines(_ d: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        storage.append(d)
        var out: [Data] = []
        while let nl = storage.firstIndex(of: 0x0A) {
            out.append(storage.subdata(in: storage.startIndex..<nl))
            storage = storage.subdata(in: (nl + 1)..<storage.endIndex)
        }
        return out
    }
}
