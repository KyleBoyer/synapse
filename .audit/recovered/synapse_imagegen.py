#!/usr/bin/env python
"""Synapse image sidecar: JSON lines on stdin/stdout. One request per line, events back per line.
stdout is protocol-only (fd 1 is reserved; library prints/tqdm go to stderr).
Requests: {"id","op":"ping|load|generate|edit|cancel|unload|shutdown", ...}
Events:   {"id","event":"ok|progress|done|error", ...}
All MLX work runs on ONE worker thread (MLX streams are per-thread); main thread only reads stdin.
SYNAPSE_MOCK=1 swaps in a fake generator (no mflux import) for protocol tests."""
import json, os, queue, sys, threading, time, traceback

OUT = os.fdopen(os.dup(1), "w", buffering=1)  # protocol channel
os.dup2(2, 1); sys.stdout = sys.stderr          # anything else that prints goes to stderr
_lock = threading.Lock()
def emit(**ev):
    with _lock: OUT.write(json.dumps(ev) + "\n")

MOCK = os.environ.get("SYNAPSE_MOCK") == "1"
cancel = threading.Event()
state = {"model": None, "kind": None}

class Progress:  # mflux InLoopCallback protocol; registered via model.callbacks.register()
    def __init__(self, rid): self.rid = rid
    def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
        emit(id=self.rid, event="progress", step=t + 1, total=config.num_inference_steps)
        if cancel.is_set(): raise KeyboardInterrupt  # mflux turns this into StopImageGenerationException

def do_load(r):
    kind, path, q = r["kind"], r["model_path"], r.get("quantize")  # kind: qwen-image | qwen-edit | qwen-2.1
    if MOCK: state.update(model=object(), kind=kind); return
    # q must be None for prequantized checkpoints (mlx-community/*-4bit, *-mflux-q4) - bits come from the files.
    if kind == "qwen-image":
        from mflux.models.qwen.variants.txt2img.qwen_image import QwenImage as M
    elif kind == "qwen-edit":
        from mflux.models.qwen.variants.edit.qwen_image_edit import QwenImageEdit as M
    elif kind == "qwen-2.1":
        from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21 as M
    else: raise ValueError(f"unknown kind {kind}")
    state.update(model=M(quantize=q, model_path=path), kind=kind)  # local dir => no HF access at all

def do_gen(r, edit):
    m = state["model"]
    if m is None: raise RuntimeError("no model loaded")
    out = r["output_path"]
    if MOCK:
        from PIL import Image
        n = r.get("steps", 4)
        for i in range(n):
            time.sleep(0.05); emit(id=r["id"], event="progress", step=i + 1, total=n)
            if cancel.is_set(): raise InterruptedError("cancelled")
        Image.new("RGB", (r.get("width", 64), r.get("height", 64)), (r["seed"] % 256, 80, 160)).save(out)
        return out
    m.callbacks.register(Progress(r["id"]))
    kw = dict(seed=r["seed"], prompt=r["prompt"], num_inference_steps=r.get("steps", 20),
              guidance=r.get("guidance", 4.0), negative_prompt=r.get("negative_prompt"))
    if edit: kw.update(image_paths=[r["image_path"]], width=r.get("width"), height=r.get("height"))
    else:    kw.update(width=r.get("width", 1024), height=r.get("height", 1024))
    try:
        img = m.generate_image(**kw)       # GeneratedImage; .image is a PIL.Image
        img.image.save(out)
    finally:
        m.callbacks.in_loop.clear()        # drop our Progress so callbacks don't accumulate
    return out

def work(q):
    import gc
    while True:
        r = q.get()
        if r is None: return
        rid, op = r.get("id"), r["op"]
        try:
            cancel.clear()
            if op == "load": do_load(r); emit(id=rid, event="ok", kind=state["kind"])
            elif op in ("generate", "edit"): emit(id=rid, event="done", path=do_gen(r, op == "edit"))
            elif op == "unload":
                state.update(model=None, kind=None); gc.collect()
                if not MOCK:
                    import mlx.core as mx; mx.clear_cache()
                emit(id=rid, event="ok")
        except (KeyboardInterrupt, InterruptedError, Exception) as e:
            name = type(e).__name__
            emit(id=rid, event="error", code="cancelled" if "Stop" in name or "Interrupt" in name else "failed",
                 message=str(e), trace=traceback.format_exc(limit=3))

def main():
    q = queue.Queue(); t = threading.Thread(target=work, args=(q,), daemon=True); t.start()
    emit(event="ready", pid=os.getpid(), mock=MOCK, protocol=1)
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except json.JSONDecodeError as e: emit(event="error", code="bad_json", message=str(e)); continue
        op = r.get("op")
        if op == "ping": emit(id=r.get("id"), event="ok", loaded=state["kind"])  # answered even while generating
        elif op == "cancel": cancel.set(); emit(id=r.get("id"), event="ok")
        elif op == "shutdown": cancel.set(); q.put(None); t.join(timeout=30); emit(id=r.get("id"), event="ok"); return
        elif op in ("load", "generate", "edit", "unload"): q.put(r)
        else: emit(id=r.get("id"), event="error", code="bad_op", message=str(op))
    cancel.set(); q.put(None)  # stdin closed => parent died; exit

if __name__ == "__main__": main()
