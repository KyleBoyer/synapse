import Foundation
import Synchronization

/// A text-to-speech model run by mlx-audio in a sidecar that keeps it loaded (Qwen3-TTS, VoxCPM2, Chatterbox Turbo).
/// Each request may carry a reference clip and its transcript, which is how these models clone a voice.
final class MLXAudioSpeech: @unchecked Sendable {
    let sampleRate: Int
    private let process: Process
    private let input: FileHandle
    private let lines: LineQueue
    private let logName: String
    private let gate = AsyncSerial()   // the sidecar handles one request at a time

    private init(sampleRate: Int, process: Process, input: FileHandle, lines: LineQueue, logName: String) {
        self.sampleRate = sampleRate; self.process = process; self.input = input; self.lines = lines; self.logName = logName
    }

    static func launch(folder: URL, modelID: String) async throws -> MLXAudioSpeech {
        let rt = try await PythonRuntime.shared.ensureInstalled(.init(name: "mlx-audio", requirements: ["mlx-audio==\(MLXAudioSoundEngine.version)"]),
                                                                storeRoot: try PythonRuntime.storeRoot(above: folder))
        let p = Process()
        p.executableURL = rt.python
        p.arguments = ["-c", MLXAudioSpeechScript.source, folder.path]
        // Not offline: Chatterbox fetches its speech tokenizer (mlx-community/S3TokenizerV2) into the runtime's cache
        // on first use. Model weights always come from the local folder.
        p.environment = ProcessInfo.processInfo.environment.merging([
            "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
            "HF_HOME": rt.dir.appending(path: "hf").path, "PYTHONUNBUFFERED": "1",
        ]) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        let logName = "synapse-speech-\(modelID).log"
        let logURL = FileManager.default.temporaryDirectory.appending(path: logName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        let lines = LineQueue()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; lines.close() } else { lines.feed(d) }
        }
        try p.run()
        guard let first = try await lines.next(timeout: 600) else {
            p.terminate()
            let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
            throw EngineError.unsupported("The speech model exited while loading: \(tail)")
        }
        if let fatal = first["fatal"] as? String { p.terminate(); throw EngineError.unsupported(fatal) }
        return MLXAudioSpeech(sampleRate: first["sample_rate"] as? Int ?? 24000, process: p, input: stdin.fileHandleForWriting,
                              lines: lines, logName: logName)
    }

    /// Speech for `text`, in the voice of `reference` when given. Audio streams as the model produces it.
    func synthesize(_ text: String, reference: VoiceReference?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        let id = UUID().uuidString
        let finished = Mutex(false)
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    try await gate.run { try await self.run(id, text, reference, speed) { c.yield($0) } }
                    c.finish()
                } catch { c.finish(throwing: error) }
                finished.withLock { $0 = true }
            }
            c.onTermination = { [weak self] _ in
                guard !finished.withLock({ $0 }) else { return }
                self?.send(["cancel": id])   // the sidecar stops at its next chunk and still sends `done`
                _ = task
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: obj) else { return }
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    private func run(_ id: String, _ text: String, _ reference: VoiceReference?, _ speed: Double,
                     yield: @escaping @Sendable ([Float]) -> Void) async throws {
        var req: [String: Any] = ["id": id, "text": text, "speed": speed]
        if let reference {
            req["ref_audio"] = reference.sample.path
            if let t = reference.transcript { req["ref_text"] = t }
        }
        // MLX on the GPU: one model at a time across the app.
        await GPUGate.shared.acquire()
        let gpu = GateRelease()
        defer { gpu() }
        send(req)
        while true {
            guard let r = try await lines.next(timeout: 600) else {
                throw EngineError.unsupported("The speech model stopped (see \(logName) in the temp folder).")
            }
            guard r["id"] as? String == id else { continue }   // a cancelled request's last lines
            if let e = r["error"] as? String { throw EngineError.unsupported("The speech model failed: \(e)") }
            if let b = r["audio"] as? String, let d = Data(base64Encoded: b) {
                yield(d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
            }
            if r["done"] as? Bool == true { return }
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

/// The mlx-audio speech sidecar. Loads one model, then answers requests read from stdin, one JSON object per line:
///   {"id", "text", "speed", "ref_audio"?: path, "ref_text"?}   or   {"cancel": id}
/// Replies are lines starting with "SYNAPSE ": first {"ready", "sample_rate"} (or {"fatal"}), then per request
/// {"id", "audio": base64 float32 LE} as chunks come, and {"id", "done": true} or {"id", "error"}.
enum MLXAudioSpeechScript {
    static let source = #"""
import base64, inspect, json, os, queue, sys, threading, time, traceback

parent = os.getppid()
def watch():
    # Exit with Synapse: a child outlives a parent that quits or crashes, and this one holds a model.
    while True:
        time.sleep(1)
        if os.getppid() != parent:
            os._exit(0)
threading.Thread(target=watch, daemon=True).start()

def reply(obj):
    sys.stdout.write("SYNAPSE " + json.dumps(obj) + "\n")
    sys.stdout.flush()

try:
    from pathlib import Path
    import numpy as np
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model
    model = load_model(Path(sys.argv[1]))
except Exception as e:
    traceback.print_exc()
    reply({"fatal": f"Could not load the speech model: {e}"})
    sys.exit(1)

rate = int(getattr(model, "sample_rate", 24000))
params = inspect.signature(model.generate).parameters
open_kwargs = any(p.kind == p.VAR_KEYWORD for p in params.values())
def accepted(kwargs):
    # Models take different options; pass only what this one's generate() declares.
    return {k: v for k, v in kwargs.items() if v is not None and (open_kwargs or k in params)}

requests, cancelled = queue.Queue(), set()
def read():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "cancel" in msg:
            cancelled.add(msg["cancel"])
        else:
            requests.put(msg)
    os._exit(0)
threading.Thread(target=read, daemon=True).start()
reply({"ready": True, "sample_rate": rate})

while True:
    req = requests.get()
    rid = req["id"]
    try:
        kwargs = accepted({"ref_audio": req.get("ref_audio"), "ref_text": req.get("ref_text"),
                           "speed": req.get("speed") if req.get("speed") not in (None, 1, 1.0) else None})
        for r in model.generate(text=req["text"], **kwargs):
            if rid in cancelled:
                break
            a = np.array(r.audio, dtype=np.float32).reshape(-1)
            if int(getattr(r, "sample_rate", rate)) != rate:
                raise RuntimeError(f"model changed sample rate to {r.sample_rate}")
            if a.size:
                reply({"id": rid, "audio": base64.b64encode(a.astype("<f4").tobytes()).decode()})
        reply({"id": rid, "done": True})
    except Exception as e:
        traceback.print_exc()
        reply({"id": rid, "error": str(e)})
    cancelled.discard(rid)
    mx.clear_cache()
"""#
}
