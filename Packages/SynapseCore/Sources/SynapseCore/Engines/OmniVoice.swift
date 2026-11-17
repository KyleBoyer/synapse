import Foundation
import Synchronization

/// What an omni model produces while it answers out loud.
public enum VoiceEvent: Sendable, Equatable {
    case text(String)
    case audio([Float], sampleRate: Int)
    case done(promptTokens: Int, generationTokens: Int)
}

/// A chat model that answers in its own voice (an omni model with speech output).
public protocol RealtimeVoiceLLM: Sendable {
    var modelID: String { get }
    /// `messages` as in chat; the last user message may carry audio (WAV files) and images. Ending the stream
    /// early (barge-in) stops generation.
    func respond(_ messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<VoiceEvent, Error>
}

public enum OmniVoices {
    /// mlx-vlm models whose weights include a speech decoder (`generate_audio`). MiniCPM-o also needs audio in the
    /// turn, which a voice call always has.
    public static let speaking: Set<String> = ["lfm3-omni-2b", "minicpm-o-4.5"]
    public static func canSpeak(_ spec: ModelSpec) -> Bool { spec.engine == .mlxvlm && speaking.contains(spec.id) }

    /// Leases the model's voice sidecar; eviction stops it.
    static func lease(_ spec: ModelSpec, store: ModelStore, models: ModelManager) async throws -> ModelLease<OmniVoice> {
        guard let folder = await store.folder(for: spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        try await ModelPrep.prepareIfNeeded(spec, folder: folder)   // downloaded before prep existed
        return try await models.lease("voice:\(spec.id)", as: OmniVoice.self, estimatedBytes: spec.estimatedBytes) {
            let v = try await OmniVoice.launch(folder: folder, modelID: spec.id)
            return (v, unload: { v.terminate() })
        }
    }
}

/// The omni voice sidecar process: one request at a time over stdin, replies on stdout (see OmniVoiceScript).
public final class OmniVoice: @unchecked Sendable {
    let modelID: String
    private let process: Process
    private let input: FileHandle
    private let lines: LineQueue
    private let gate = AsyncSerial()   // one request in flight; the sidecar is sequential

    private init(modelID: String, process: Process, input: FileHandle, lines: LineQueue) {
        self.modelID = modelID; self.process = process; self.input = input; self.lines = lines
    }

    static func launch(folder: URL, modelID: String) async throws -> OmniVoice {
        let rt = try await PythonRuntime.shared.ensureInstalled(.init(name: "mlx-vlm", requirements: ["mlx-vlm==\(MLXVLMServer.version)"]),
                                                                storeRoot: try PythonRuntime.storeRoot(above: folder))
        let p = Process()
        p.executableURL = rt.python
        p.arguments = ["-c", OmniVoiceScript.source, folder.path]
        // Not offline: some voices fetch small companion assets on first use (MiniCPM-o's Step-Audio-2 vocoder and
        // CosyVoice2 tokenizer, ~1 GB) into the runtime's own cache. Model weights always come from the local folder.
        p.environment = ProcessInfo.processInfo.environment.merging([
            "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
            "HF_HOME": rt.dir.appending(path: "hf").path, "PYTHONUNBUFFERED": "1",
        ]) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        let logURL = FileManager.default.temporaryDirectory.appending(path: "synapse-omnivoice-\(modelID).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        let lines = LineQueue()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; lines.close() } else { lines.feed(d) }
        }
        try p.run()
        let voice = OmniVoice(modelID: modelID, process: p, input: stdin.fileHandleForWriting, lines: lines)
        // Loading can take a minute the first time (Metal kernels, weights from disk).
        guard let first = try await lines.next(timeout: 600) else {
            voice.terminate()
            let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
            throw EngineError.unsupported("The voice model exited while loading: \(tail)")
        }
        if let fatal = first["fatal"] as? String { voice.terminate(); throw EngineError.unsupported(fatal) }
        return voice
    }

    func respond(_ messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<VoiceEvent, Error> {
        let id = UUID().uuidString
        let finished = Mutex(false)
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    try await gate.run { try await self.run(id, messages, options) { c.yield($0) } }
                    c.finish()
                } catch { c.finish(throwing: error) }
                finished.withLock { $0 = true }
            }
            c.onTermination = { [weak self] _ in
                guard !finished.withLock({ $0 }) else { return }
                // Barge-in: the sidecar stops at its next check and still sends `done`, which `run` waits for.
                self?.send(["cancel": id])
                _ = task
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: obj) else { return }
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    /// Sends one request and relays its replies until `done`. Image attachments become temp files the sidecar reads.
    private func run(_ id: String, _ messages: [ChatMessage], _ options: ChatOptions,
                     yield: @escaping @Sendable (VoiceEvent) -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-voice", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var images: [String] = [], audios: [String] = [], wire: [[String: Any]] = []
        defer { for i in images { try? FileManager.default.removeItem(atPath: i) } }
        for m in messages {
            for img in m.images {
                let f = dir.appending(path: "\(UUID().uuidString).jpg")
                try img.write(to: f)
                images.append(f.path)
            }
            audios += m.audios.map(\.path)
            wire.append(["role": m.role.rawValue, "content": m.text])
        }
        var req: [String: Any] = ["id": id, "messages": wire, "images": images, "audios": audios, "max_tokens": options.maxTokens ?? 512]
        if let t = options.temperature { req["temperature"] = t }
        await GPUGate.shared.acquire()
        let gpu = GateRelease()
        defer { gpu() }
        send(req)
        while true {
            guard let r = try await lines.next(timeout: 600) else {
                throw EngineError.unsupported("The voice model stopped (see synapse-omnivoice-\(modelID).log in the temp folder).")
            }
            guard r["id"] as? String == id else { continue }   // a cancelled request's last lines
            if let e = r["error"] as? String { throw EngineError.unsupported("The voice model failed: \(e)") }
            if let t = r["text"] as? String { yield(.text(t)) }
            if let b = r["audio"] as? String, let d = Data(base64Encoded: b) {
                yield(.audio(d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, sampleRate: r["sample_rate"] as? Int ?? 24000))
            }
            if r["done"] as? Bool == true {
                yield(.done(promptTokens: r["prompt_tokens"] as? Int ?? 0, generationTokens: r["generation_tokens"] as? Int ?? 0))
                return
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
}

/// Holds a ModelLease while a RealtimeVoiceLLM is in use; the GPU gate is taken per reply.
final class LeasedOmniVoice: RealtimeVoiceLLM, @unchecked Sendable {
    let modelID: String
    private let lease: ModelLease<OmniVoice>
    init(_ lease: ModelLease<OmniVoice>) { self.lease = lease; modelID = lease.value.modelID }
    func respond(_ messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<VoiceEvent, Error> {
        lease.value.respond(messages, options: options)
    }
    deinit { lease.release() }
}

/// Lines from the sidecar that start with "SYNAPSE ", parsed as JSON; everything else (library logs) is skipped.
final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var ready: [[String: Any]] = []
    private var closed = false
    private var waiter: CheckedContinuation<[String: Any]?, Never>?

    func feed(_ d: Data) {
        var handoff: (CheckedContinuation<[String: Any]?, Never>, [String: Any])?
        lock.withLock {
            buffer.append(d)
            while let i = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
                buffer = buffer.subdata(in: (i + 1)..<buffer.endIndex)
                guard line.hasPrefix("SYNAPSE "),
                      let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(8).utf8)) as? [String: Any] else { continue }
                ready.append(o)
            }
            if let w = waiter, !ready.isEmpty { waiter = nil; handoff = (w, ready.removeFirst()) }
        }
        if let (w, item) = handoff { w.resume(returning: item) }
    }

    func close() {
        let w = lock.withLock { () -> CheckedContinuation<[String: Any]?, Never>? in closed = true; let w = waiter; waiter = nil; return w }
        w?.resume(returning: nil)
    }

    /// The next reply, or nil when the process closed its output or `timeout` seconds passed.
    func next(timeout: Double) async throws -> [String: Any]? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            let w = self.lock.withLock { () -> CheckedContinuation<[String: Any]?, Never>? in let w = self.waiter; self.waiter = nil; return w }
            w?.resume(returning: nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { c in
            let now: [String: Any]?? = lock.withLock {
                if !ready.isEmpty { return .some(ready.removeFirst()) }
                if closed { return .some(nil) }
                waiter = c
                return nil
            }
            if let now { c.resume(returning: now) }
        }
    }
}

/// Runs async bodies one at a time, in call order.
actor AsyncSerial {
    private var tail: Task<Void, Never>?
    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> { await previous?.value; return try await body() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
