import Foundation
import Synchronization

/// Qwen3-VL Embedding and SigLIP2: text and images in one vector space, through mlx-embeddings in a sidecar that keeps
/// the model loaded. Images go to the sidecar as temp files.
enum ImageTextEmbedder {
    /// mlx-embeddings imports mlx-lm (Qwen3-VL) and mlx-vlm (image loading) without declaring them.
    static let runtime = PythonRuntime.Spec(name: "mlx-embeddings",
                                            requirements: ["mlx-embeddings==0.1.0", "mlx-lm==0.32.2", "mlx-vlm==0.8.0"])

    static func embed(_ spec: ModelSpec, folder: URL, inputs: [EmbeddingInput], models: ModelManager) async throws -> EmbeddingResult {
        let lease = try await models.lease(spec.id, as: PythonSidecar.self,
                                           estimatedBytes: spec.recommendedRAMGB.map { $0 << 30 } ?? spec.estimatedBytes) {
            let s = try await PythonSidecar.launch(runtime: runtime, script: script, folder: folder, logName: "synapse-embed-\(spec.id).log")
            return (s, unload: { s.terminate() })
        }
        defer { lease.release() }

        let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-embed/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var items: [[String: Any]] = []
        for (i, input) in inputs.enumerated() {
            var item: [String: Any] = [:]
            if let t = input.text { item["text"] = t }
            if let image = input.image {
                let f = dir.appending(path: "\(i).\(image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg")")
                try image.write(to: f)
                item["image"] = f.path
            }
            if !input.videoFrames.isEmpty {
                // shortcut: mlx-embeddings 0.1.0 turns Qwen3-VL's video processor off, so a video goes in as its frames
                // (several images in one input); send real video when a release enables it.
                var paths: [String] = []
                for (j, frame) in input.videoFrames.enumerated() {
                    let f = dir.appending(path: "\(i)-\(j).jpg")
                    try frame.write(to: f)
                    paths.append(f.path)
                }
                item["image"] = paths
            }
            items.append(item)
        }
        let id = UUID().uuidString
        let line = try PythonSidecar.line(["items": items], id: id)
        let vectors = Mutex<[[Float]]>([]), tokens = Mutex(0)
        await GPUGate.shared.acquire()
        let gpu = GateRelease()
        defer { gpu() }
        try await lease.value.exchange(line, id: id) { r in
            guard let b = r["vectors"] as? String, let d = Data(base64Encoded: b), let dims = r["dims"] as? Int, dims > 0 else { return }
            tokens.withLock { $0 = r["tokens"] as? Int ?? 0 }
            let flat = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            vectors.withLock { v in v = stride(from: 0, to: flat.count, by: dims).map { Array(flat[$0..<min($0 + dims, flat.count)]) } }
        }
        let out = vectors.withLock { $0 }
        guard out.count == inputs.count else { throw EmbeddingError.badInput("The model returned \(out.count) vectors for \(inputs.count) inputs.") }
        return EmbeddingResult(vectors: out, promptTokens: tokens.withLock { $0 })
    }

    /// Request: {"id", "items": [{"text"?, "image"?: path or [paths] (video frames, Qwen3-VL)}]}. Ready: {"ready", "kind"}. Reply: {"id", "dims",
    /// "vectors": base64 float32 LE, unit length, row per item, "tokens", "done": true}.
    static let script = PythonSidecar.prelude + #"""
import base64, tempfile
try:
    from pathlib import Path
    import numpy as np
    import mlx.core as mx
    from mlx_embeddings import load, generate
    model, proc = load(sys.argv[1])
    config = json.load(open(Path(sys.argv[1]) / "config.json"))
    kind = config.get("model_type")
except Exception as e:
    traceback.print_exc()
    reply({"fatal": f"Could not load the embedding model: {e}"})
    sys.exit(1)

# SigLIP's towers are independent, but its generate() needs images whenever it gets texts; this one is ignored.
placeholder = None
def blank_image():
    global placeholder
    if placeholder is None:
        from PIL import Image
        placeholder = tempfile.NamedTemporaryFile(suffix=".png", delete=False).name
        Image.new("RGB", (32, 32), "white").save(placeholder)
    return placeholder

def unit(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)

def siglip_tokens(items):
    # mlx-embeddings reports no usage: text tokens from the tokenizer, plus one per image patch.
    tok = getattr(proc, "tokenizer", proc)
    vision = config.get("vision_config", {})
    patches = (vision.get("image_size", 384) // vision.get("patch_size", 16)) ** 2
    return sum(len(tok(it["text"])["input_ids"]) if "image" not in it else patches for it in items)

def embed(items):
    """Vectors (row per item) and the prompt tokens they took."""
    if kind == "qwen3_vl":
        rows = [{k: v for k, v in it.items() if k in ("text", "image")} for it in items]
        # model.embed() without discarding the inputs, so the attention mask gives the token count.
        inputs = proc.prepare_embedding_inputs(rows)
        out = model(**inputs).text_embeds
        return np.array(out, dtype=np.float32), int(np.array(inputs["attention_mask"]).sum())
    if any("text" in it and "image" in it for it in items):
        raise ValueError("SigLIP2 embeds text or an image, not both as one input; use qwen3-vl-embedding-2b for that.")
    texts = [it["text"] for it in items if "image" not in it]
    images = [it["image"] for it in items if "image" in it]
    out = generate(model, proc, texts or [""], images=images or [blank_image()])
    tv, iv = np.array(out.text_embeds, dtype=np.float32), np.array(out.image_embeds, dtype=np.float32)
    rows, t, i = [], 0, 0
    for it in items:
        if "image" in it:
            rows.append(iv[i]); i += 1
        else:
            rows.append(tv[t]); t += 1
    return np.stack(rows), siglip_tokens(items)

reply({"ready": True, "kind": kind})
for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    rid = req.get("id")
    try:
        items = req["items"]
        vecs, tokens = embed(items)
        vecs = unit(vecs.reshape(len(items), -1))
        reply({"id": rid, "dims": int(vecs.shape[1]), "vectors": base64.b64encode(vecs.astype("<f4").tobytes()).decode(),
               "tokens": int(tokens), "done": True})
    except Exception as e:
        traceback.print_exc()
        reply({"id": rid, "error": str(e)})
    mx.clear_cache()
"""#
}
