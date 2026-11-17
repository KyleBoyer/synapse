/// Runs mlx-video's LTX-2 generator with the transformer quantized as it loads, for Macs that cannot hold its 22B
/// parameters in bf16 (~44 GB). `mx.load` is lazy, so quantizing after `load_weights` and before evaluation means the
/// bf16 weights never all sit in memory: each chunk is read, quantized and dropped. Bits come from SYNAPSE_LTX_BITS.
/// The text encoder's Gemma arrives quantized (its config says so); its projection and connector layers (6.3 GB
/// of bf16 in LTX-2.3) are quantized here right after `load`, before mlx-video evaluates them.
enum LTXLowMemoryScript {
    static let source = #"""
import json, os, runpy, sys
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_flatten
from mlx_video.models.ltx_2 import ltx_2 as L
from mlx_video.models.ltx_2 import text_encoder as TE

BITS = int(os.environ.get("SYNAPSE_LTX_BITS", "4"))
GROUP = 64

def quantizable(path, module):
    return isinstance(module, nn.Linear) and module.weight.shape[-1] % GROUP == 0

def materialize(model):
    """Evaluates parameters a chunk at a time, so each bf16 source is read, quantized and dropped in turn."""
    params = [v for _, v in tree_flatten(model.parameters())]
    for i in range(0, len(params), 64):
        mx.eval(params[i:i + 64])
        mx.clear_cache()

_load_text_encoder = TE.LTX2TextEncoder.load

def load_text_encoder(self, *args, **kwargs):
    _load_text_encoder(self, *args, **kwargs)
    nn.quantize(self, group_size=GROUP, bits=4,
                class_predicate=lambda p, m: not p.startswith("language_model") and quantizable(p, m))
    materialize(self)
    print(f"Text projections quantized to 4-bit; active {mx.get_active_memory() / 1e9:.1f} GB", flush=True)

TE.LTX2TextEncoder.load = load_text_encoder

def from_pretrained(cls, model_path, strict=True):
    model_path = Path(model_path)
    with open(model_path / "config.json") as f:
        model = cls(L.LTXModelConfig(**json.load(f)))
    weights = {}
    for weight_file in model_path.glob("*.safetensors"):
        weights.update(mx.load(str(weight_file)))
    sanitized = {k: v.astype(mx.bfloat16) if v.dtype == mx.float32 else v for k, v in model.sanitize(weights).items()}
    del weights
    model.load_weights(list(sanitized.items()), strict=strict)
    del sanitized
    nn.quantize(model, group_size=GROUP, bits=BITS, class_predicate=quantizable)
    materialize(model)
    model.eval()
    print(f"Transformer quantized to {BITS}-bit while loading; active {mx.get_active_memory() / 1e9:.1f} GB", flush=True)
    return model

L.LTXModel.from_pretrained = classmethod(from_pretrained)
sys.argv = ["mlx_video.models.ltx_2.generate"] + sys.argv[1:]
runpy.run_module("mlx_video.models.ltx_2.generate", run_name="__main__")
"""#
}
