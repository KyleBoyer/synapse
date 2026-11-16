// Generated from the standalone sidecar script; edit here, the engine writes it to the runtime folder at startup.
enum MFluxSidecarScript {
    static let source = #"""
#!/usr/bin/env python
"""Synapse image sidecar (mflux). JSON lines on stdin/stdout; stdout carries the protocol only.
Requests: {"id","op":"load|generate|edit|cancel|unload|shutdown", ...}
Events:   {"event":"ready"} / {"id","event":"ok|progress|done|error", ...}
MLX work runs on ONE worker thread (MLX streams are per-thread); the main thread reads stdin so
`cancel` is handled mid-generation. SYNAPSE_MOCK=1 swaps in a fake generator for protocol tests."""
import base64, gc, io, json, os, queue, sys, tempfile, threading, time, traceback

OUT = os.fdopen(os.dup(1), "w", buffering=1)  # protocol channel
os.dup2(2, 1); sys.stdout = sys.stderr          # stray prints (mflux, tqdm) go to stderr
_lock = threading.Lock()
def emit(**ev):
    with _lock: OUT.write(json.dumps(ev) + "\n")

MOCK = os.environ.get("SYNAPSE_MOCK") == "1"
cancel = threading.Event()
state = {"model": None, "kind": None}

class Progress:  # mflux in-loop callback; raising KeyboardInterrupt makes mflux stop cleanly
    def __init__(self, rid): self.rid = rid
    def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
        emit(id=self.rid, event="progress", step=t + 1, total=config.num_inference_steps)
        if cancel.is_set(): raise KeyboardInterrupt

def do_load(r):
    kind, path = r["kind"], r["model_path"]  # kind: qwen-image | qwen-edit | qwen-edit-2511 | qwen-2.1
    if MOCK: state.update(model=object(), kind=kind); return
    # quantize=None: the repos are pre-quantized, bit width comes from the files.
    if kind == "qwen-2.1":
        from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21
        m = QwenImage21(quantize=None, model_path=path)
    elif kind == "qwen-image":
        from mflux.models.qwen.variants.txt2img.qwen_image import QwenImage
        m = QwenImage(quantize=None, model_path=path)
    elif kind in ("qwen-edit", "qwen-edit-2511"):
        from mflux.models.common.config import ModelConfig
        from mflux.models.qwen.variants.edit.qwen_image_edit import QwenImageEdit
        cfg = ModelConfig.qwen_image_edit_2511() if kind == "qwen-edit-2511" else ModelConfig.qwen_image_edit()
        m = QwenImageEdit(quantize=None, model_path=path, model_config=cfg)
    else: raise ValueError(f"unknown kind {kind}")
    state.update(model=m, kind=kind)

def do_gen(r, edit):
    m = state["model"]
    if m is None: raise RuntimeError("no model loaded")
    rid, steps = r["id"], r["steps"]
    if MOCK:
        from PIL import Image
        for i in range(steps):
            time.sleep(0.05); emit(id=rid, event="progress", step=i + 1, total=steps)
            if cancel.is_set(): raise InterruptedError("cancelled")
        buf = io.BytesIO(); Image.new("RGB", (r["width"], r["height"]), (r["seed"] % 256, 80, 160)).save(buf, "PNG")
        return buf.getvalue()
    kw = dict(seed=r["seed"], prompt=r["prompt"], num_inference_steps=steps, guidance=r["guidance"],
              negative_prompt=r.get("negative_prompt"), width=r["width"], height=r["height"])
    m.callbacks.register(Progress(rid))
    try:
        with tempfile.TemporaryDirectory() as tmp:
            if edit:
                paths = []
                for i, b in enumerate(r["images"]):
                    p = os.path.join(tmp, f"in{i}.png"); open(p, "wb").write(base64.b64decode(b)); paths.append(p)
                kw["image_paths"] = paths
            img = m.generate_image(**kw).image  # PIL.Image
            buf = io.BytesIO(); img.save(buf, "PNG"); return buf.getvalue()
    finally:
        m.callbacks.in_loop.clear()  # drop our Progress so callbacks don't accumulate
        cache = getattr(m, "prompt_cache", None)
        if hasattr(cache, "clear"): cache.clear()

def free():
    gc.collect()
    if not MOCK:
        import mlx.core as mx; mx.clear_cache()

def work(q):
    while True:
        r = q.get()
        if r is None: return
        rid, op = r.get("id"), r["op"]
        try:
            cancel.clear()
            if op == "load": do_load(r); emit(id=rid, event="ok")
            elif op in ("generate", "edit"):
                png = do_gen(r, op == "edit"); free()
                emit(id=rid, event="done", png_b64=base64.b64encode(png).decode())
            elif op == "unload": state.update(model=None, kind=None); free(); emit(id=rid, event="ok")
        except BaseException as e:
            free()
            name = type(e).__name__
            emit(id=rid, event="error", cancelled="Stop" in name or "Interrupt" in name,
                 message=f"{name}: {e}", trace=traceback.format_exc(limit=4))

def main():
    q = queue.Queue(); t = threading.Thread(target=work, args=(q,), daemon=True); t.start()
    emit(event="ready", pid=os.getpid(), mock=MOCK)
    for line in sys.stdin:
        if not line.strip(): continue
        try: r = json.loads(line)
        except json.JSONDecodeError as e: emit(event="error", message=f"bad json: {e}"); continue
        op = r.get("op")
        if op == "cancel": cancel.set()
        elif op == "shutdown": cancel.set(); q.put(None); t.join(timeout=30); emit(id=r.get("id"), event="ok"); return
        elif op in ("load", "generate", "edit", "unload"): q.put(r)
        else: emit(id=r.get("id"), event="error", message=f"unknown op {op}")
    cancel.set(); q.put(None)  # stdin closed => parent died; exit

if __name__ == "__main__": main()
"""#
}
