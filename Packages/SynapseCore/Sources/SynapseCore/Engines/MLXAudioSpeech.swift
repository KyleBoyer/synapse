import Foundation
import Synchronization

/// A text-to-speech model run by mlx-audio in a sidecar that keeps it loaded (Qwen3-TTS, VoxCPM2, Chatterbox Turbo).
/// Each request may carry a reference clip and its transcript, which is how these models clone a voice.
final class MLXAudioSpeech: @unchecked Sendable {
    let sampleRate: Int
    private let sidecar: PythonSidecar

    private init(sampleRate: Int, sidecar: PythonSidecar) { self.sampleRate = sampleRate; self.sidecar = sidecar }

    static func launch(folder: URL, modelID: String) async throws -> MLXAudioSpeech {
        // Not offline: Chatterbox fetches its speech tokenizer (mlx-community/S3TokenizerV2) on first use.
        let s = try await PythonSidecar.launch(runtime: .init(name: "mlx-audio", requirements: ["mlx-audio==\(MLXAudioSoundEngine.version)"]),
                                               script: MLXAudioSpeechScript.source, folder: folder,
                                               logName: "synapse-speech-\(modelID).log", offline: false)
        return MLXAudioSpeech(sampleRate: s.ready["sample_rate"] as? Int ?? 24000, sidecar: s)
    }

    /// Speech for `text`, in the voice of `reference` when given. Audio streams as the model produces it.
    func synthesize(_ text: String, reference: VoiceReference?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        var req: [String: Any] = ["text": text, "speed": speed]
        if let reference {
            req["ref_audio"] = reference.sample.path
            if let t = reference.transcript { req["ref_text"] = t }
        }
        return stream(req)
    }

    /// `source` (a 16 kHz WAV of someone speaking) re-spoken in the voice of `reference`, piece by piece.
    func convert(source: URL, reference: VoiceReference) -> AsyncThrowingStream<[Float], Error> {
        stream(["source": source.path, "ref_audio": reference.sample.path])
    }

    private func stream(_ req: [String: Any]) -> AsyncThrowingStream<[Float], Error> {
        let id = UUID().uuidString
        let finished = Mutex(false)
        let line: Data
        do { line = try PythonSidecar.line(req, id: id) } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return AsyncThrowingStream { c in
            let task = Task { [sidecar] in
                do {
                    // MLX on the GPU: one model at a time across the app.
                    await GPUGate.shared.acquire()
                    let gpu = GateRelease()
                    defer { gpu() }
                    try await sidecar.exchange(line, id: id) { r in
                        if let b = r["audio"] as? String, let d = Data(base64Encoded: b) {
                            c.yield(d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
                        }
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
                finished.withLock { $0 = true }
            }
            c.onTermination = { [sidecar] _ in
                guard !finished.withLock({ $0 }) else { return }
                sidecar.send(["cancel": id])   // the sidecar stops at its next chunk and still sends `done`
                _ = task
            }
        }
    }

    func terminate() { sidecar.terminate() }
}

/// The mlx-audio speech sidecar (see PythonSidecar for the protocol). Requests: {"id", "text", "speed", "ref_audio"?:
/// path, "ref_text"?}, {"id", "source": 16 kHz WAV path, "ref_audio": path} (voice conversion), or {"cancel": id}. Ready line: {"ready", "sample_rate"}. Replies: {"id", "audio": base64 float32
/// LE} per chunk, then {"id", "done": true}.
enum MLXAudioSpeechScript {
    static let source = PythonSidecar.prelude + #"""
import base64, inspect, queue, re

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

def sentences(text):
    # One generate() per sentence, so the first sentence plays while the rest is made; VoxCPM2 and Qwen3-TTS would
    # otherwise return a paragraph as one piece. Fragments under 24 characters join the next sentence.
    out = []
    for p in (p.strip() for p in re.split(r"(?<=[.!?。！？])\s+|\n+", text)):
        if not p:
            continue
        if out and len(out[-1]) < 24:
            out[-1] += " " + p
        else:
            out.append(p)
    return out or [text]

def convert(req, rid):
    """Chatterbox's voice conversion: the source's speech tokens, rendered by S3Gen in the reference's voice (what
    upstream ChatterboxVC does). Pieces of 20 s keep the tokenizer within its window."""
    if getattr(model, "_s3tokenizer", None) is None or not hasattr(model, "s3gen"):
        raise ValueError("This model does not convert voices; use chatterbox-turbo.")
    from mlx_audio.utils import load_audio
    from mlx_audio.tts.models.chatterbox_turbo.models.s3gen import S3GEN_SIL
    from mlx_audio.tts.models.chatterbox_turbo.models.s3tokenizer import log_mel_spectrogram
    model.prepare_conditionals(req["ref_audio"])
    wav = np.array(load_audio(req["source"], sample_rate=16000)).reshape(-1)
    step = 16000 * 20
    for i in range(0, wav.size, step):
        piece = wav[i:i + step]
        if rid in cancelled or piece.size < 1600:
            break
        mel = log_mel_spectrogram(mx.array(piece))[None]
        tokens, _ = model._s3tokenizer(mel, mx.array([mel.shape[2]]))
        tokens = mx.concatenate([tokens.reshape(-1), mx.array([S3GEN_SIL] * 3, dtype=mx.int32)])[None]
        out, _ = model.s3gen.inference(speech_tokens=tokens, ref_dict=model._conds.gen, n_cfm_timesteps=2)
        a = np.array(out, dtype=np.float32).reshape(-1)
        if a.size:
            reply({"id": rid, "audio": base64.b64encode(a.astype("<f4").tobytes()).decode()})
        mx.clear_cache()

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
        if req.get("source"):
            convert(req, rid)
            reply({"id": rid, "done": True})
            cancelled.discard(rid)
            mx.clear_cache()
            continue
        kwargs = accepted({"ref_audio": req.get("ref_audio"), "ref_text": req.get("ref_text"),
                           "speed": req.get("speed") if req.get("speed") not in (None, 1, 1.0) else None})
        for sentence in sentences(req["text"]):
            for r in model.generate(text=sentence, **kwargs):
                if rid in cancelled:
                    break
                a = np.array(r.audio, dtype=np.float32).reshape(-1)
                if int(getattr(r, "sample_rate", rate)) != rate:
                    raise RuntimeError(f"model changed sample rate to {r.sample_rate}")
                if a.size:
                    reply({"id": rid, "audio": base64.b64encode(a.astype("<f4").tobytes()).decode()})
            if rid in cancelled:
                break
        reply({"id": rid, "done": True})
    except Exception as e:
        traceback.print_exc()
        reply({"id": rid, "error": str(e)})
    cancelled.discard(rid)
    mx.clear_cache()
"""#
}
