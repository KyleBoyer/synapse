# mflux sidecar spike (2026-11-15, M4 / 16 GB)

## 1. Bootstrap
- `uv` is on this Mac (`~/.local/bin/uv` 0.8.22) but Synapse must not rely on it: ship/download its own.
- Pinned standalone uv: `https://github.com/astral-sh/uv/releases/download/0.8.22/uv-aarch64-apple-darwin.tar.gz`
  + `.sha256` next to it (value 3f61099e261e449527141dbf125629fab33ad696468c8c90cebbac40185a306c). Verify with `shasum -a 256 -c`, untar to `Runtimes/bin/uv`. (Better: hardcode the hash in the app.)
- Isolated env (ran this; nothing global touched):
```
R=~/Library/Application\ Support/Synapse/Runtimes/mflux-0.24.0
UV_CACHE_DIR=$R/uvcache UV_PYTHON_INSTALL_DIR=$R/pythons UV_PYTHON_PREFERENCE=only-managed UV_NO_CONFIG=1 \
  uv venv --python 3.12 $R/venv
(same env) uv pip install --python $R/venv/bin/python "mflux==0.24.0"
```
- Measured: 26 s wall (fast network, cold cache). venv 1.1 GB (torch 595 MB, mlx 235 MB), managed CPython 49 MB, uv cache 1.2 GB
  (delete `uvcache` after install -> ~1.15 GB final). Python 3.12.11, mlx 0.32.4, torch 2.15, transformers 5.23, hf-hub 1.33, pillow 13.
- mflux hard-depends on torch + transformers (import of QwenImage = 0.5 s, fine). Python must be >=3.11.
- Add `UV_PYTHON_DOWNLOADS=manual`-style hygiene: always pass the 4 env vars; also set `UV_NO_CONFIG=1` so user uv.toml is ignored.

## 2. mflux 0.24.0 Python API (installed source verified)
- Classes (all `nn.Module`, load in `__init__`):
  - `mflux.models.qwen.variants.txt2img.qwen_image.QwenImage(quantize=None, model_path=None, lora_paths, lora_scales, bake_lora=True, model_config=ModelConfig.qwen_image())`
  - `mflux.models.qwen.variants.edit.qwen_image_edit.QwenImageEdit(same args, model_config=ModelConfig.qwen_image_edit())` (2511: pass `ModelConfig.qwen_image_edit_2511()`)
  - `mflux.models.qwen21.variants.txt2img.qwen_image_21.QwenImage21` (+ `edit.qwen_image_21_edit`, takes `small_text_encoder`, `compute_precision`)
- Generate (txt2img): `generate_image(seed, prompt, num_inference_steps=4, height=1024, width=1024, guidance=4.0, image_path=None, image_strength=None, scheduler="linear", negative_prompt=None, ...) -> GeneratedImage`
- Edit: `generate_image(seed, prompt, image_paths: list[str], num_inference_steps=4, height=None, width=None, guidance=4.0, negative_prompt=None, ...)`; w/h default to the reference image, floored to multiples of 16. Instruction = `prompt`.
- Result: `GeneratedImage.image` is a `PIL.Image`; `.save(path)` also writes EXIF metadata. Note default steps=4 is wrong for non-turbo; use ~20-30 (README uses 20; 2.1 base 40, 2.1-Turbo 8, guidance 1.0).
- Quantize: `quantize=None|3|4|5|6|8` (CLI QUANTIZE_CHOICES). Applies to transformer only: `QwenWeightDefinition` marks text_encoder `skip_quantization=True` (bf16, "significant semantic degradation"). Pre-quantized repos (mlx-community/*-4bit, *-mflux-q4) carry bits in the files -> pass `quantize=None`.
- Local path: `model_path="/abs/dir"` -> `PathResolution` rule "exists_locally" (HF-layout dir with vae/ transformer/ text_encoder/ tokenizer/, or mflux-save output). No network when a dir is given. `model.save_model(path)` exists to export a quantized copy.
- HF location: if `model_path` is an `org/name` id, `snapshot_download` into `huggingface_hub.constants.HF_HUB_CACHE` (read at import). Control with env `HF_HOME` / `HF_HUB_CACHE` set BEFORE launching the sidecar. Other mflux cache (LoRA, URL downloads): `MFLUX_CACHE_DIR`. Recommended for Synapse: Swift (or sidecar op) does `snapshot_download(repo, local_dir=<Synapse>/Models/<id>)` for download progress/resume control, then loads by local path; also set HF_HOME + MFLUX_CACHE_DIR under Synapse as a safety net, plus `HF_HUB_DISABLE_TELEMETRY=1`.
- Progress / cancel: `model.callbacks.register(obj)` (CallbackRegistry); obj with `call_in_loop(self, t, seed, prompt, latents, config, time_steps)` fires every step (`config.num_inference_steps` = total). Loop does `ctx.in_loop(...); mx.eval(latents)`; it catches only `KeyboardInterrupt` -> `StopImageGenerationException`. So cancel = raise KeyboardInterrupt from the callback (used in prototype).
- Memory hygiene (qwen README): `QwenImage.prompt_cache` grows per prompt; `.clear()`, `gc.collect()`, `mx.clear_cache()` in long-lived processes.
- Other families in `AVAILABLE_MODELS` (repo ids): FLUX.1 dev/schnell/Kontext-dev/Fill-dev/Redux-dev/Depth-dev/Krea-dev (black-forest-labs/FLUX.1-*), FLUX.2 klein 4B/9B/9b-kv/base (black-forest-labs/FLUX.2-klein-*), flux-3-image-klein(-base), Z-Image & Z-Image-Turbo (Tongyi-MAI/*), Qwen-Image-2512, -Edit-2509/-2511, Qwen-Image-2.1 / 2.1-Turbo (Qwen/*), FIBO family (briaai/FIBO, Fibo-lite, Fibo-Edit, Fibo-2.0-dev), ERNIE-Image(-Turbo) (baidu/*), Krea-2 (krea/*), Ming-Image (inclusionAI), Lens (Comfy-Org/Lens), iris-3b (speridlabs), ideogram-4-fp8, Boogu, MOSS-Image, Anima (circlestone-labs), SeedVR2 upscaler (numz), DepthPro. Built-in aliases: qwen-image -> Qwen/Qwen-Image-2512, qwen-image-edit -> Qwen/Qwen-Image-Edit-2509.

## 3. Repos, sizes, licenses (HF API, blobs=true)
| repo | total | parts | license |
|---|---|---|---|
| Qwen/Qwen-Image-2512 (= Qwen-Image) | 57.7 GB | TE 16.6, DiT 40.9, VAE 0.25 | apache-2.0 |
| Qwen/Qwen-Image-Edit-2509 / -2511 / -Edit | 57.7 GB | same | apache-2.0 |
| mlx-community/Qwen-Image-2512-4bit | 25.9 GB | TE 14.1 (bf16), DiT 11.5 | apache-2.0 |
| mlx-community/Qwen-Image-2512-8bit (also 3/5/6bit) | 36.1 GB | TE 14.1, DiT 21.7 | apache-2.0 |
| mlx-community/qwen-image-edit-2509-8bit, -2511-8bit; mflux-community/qwen-image-edit-2511-mflux-q8 | 37.5 GB | TE 15.5, DiT 21.7 | apache-2.0 |
| (no 4-bit Edit-2509/2511 found under mlx-community / mflux-community) | | | |
| Qwen/Qwen-Image-2.1 (new, distinct 14 GB DiT) / -Turbo | 33.1 / 32.5 GB | TE 17.5, DiT 14.2 | "other" = Qwen Research License (non-commercial!) |
| mlx-community/Qwen-Image-2.1-mflux-q4 | 9.6 GB | TE 4.3 (quantized), DiT 4.0, VAE 1.3 | apache-2.0 tag (base is Qwen Research - verify) |
| mlx-community/Qwen-Image-2.1-MLX-4bit | 10.5 GB | TE 5.1, DiT 4.0 | other |
- Qwen-Image 1.x / Edit 25xx: apache-2.0, commercial OK.  2.1 family: Qwen Research License, check before shipping commercially.
- RAM (weights resident; mflux keeps TE for the process): Qwen-Image 1.x q8 ~ 21.7+14.1 = ~36 GB; q4 ~ 11.5+14.1 = ~26 GB (+edit TE 15.5, +activations/VAE 1-3 GB). Neither fits 16 GB (swap-thrash). Official README: peak memory 2.1 base ~46 GB, q8 ~27 GB on M5 Max.
- Realistic on 16 GB: only the 2.1 pre-quantized q4 (9.6 GB weights, ~11-13 GB peak est.; tight with macOS + app, untested - I did not download). 1.x needs >=32 GB (q4) / 48 GB (q8) Macs. Synapse should gate by physical RAM and offer the 2.1 q4 (or `small_text_encoder`, ~2 GB TE) as the 16 GB path.

## 4. Sidecar protocol: recommendation = JSON lines over stdin/stdout
Why: no port allocation/firewall prompt/auth token, lifecycle tied to parent (stdin EOF => exit), trivial from Swift `Process`+`Pipe`. HTTP only worth it if multiple clients/browsers need it; not here.
- Prototype: `spike-mflux/synapse_imagegen.py` (tested with `SYNAPSE_MOCK=1`, `test_proto.sh`). Ops: ping, load{kind,model_path,quantize}, generate, edit, cancel, unload, shutdown. Events: ready, ok, progress{step,total}, done{path}, error{code,message}.
- Key design points: stdout fd dup'd so only protocol JSON reaches Swift (mflux/tqdm/hf print to stderr); all MLX work on one worker thread (MLX streams are thread-local) while main thread answers ping/cancel mid-generation; images written to PNG path given by Swift (no base64); cancel via KeyboardInterrupt in step callback; unload = drop model + gc + `mx.clear_cache()`. Real mflux call path is in `do_load`/`do_gen` (not executed: no weights). Imports verified OK in the venv.
- Launch: `venv/bin/python -I synapse_imagegen.py` with env HF_HOME, HF_HUB_CACHE, MFLUX_CACHE_DIR, HF_HUB_DISABLE_TELEMETRY, TOKENIZERS_PARALLELISM=false.

## 5. vOOM
- `~/git/vOOM/.venv`: Python 3.14.6 (Homebrew `python@3.14`, `include-system-site-packages = true`), mlx 0.32.0 (+mlx-lm 0.31.3, mlx-vlm 0.7.12). No pyproject/requirements; setup is `python3 -m venv --system-site-packages .venv` + pip install (README l.89). Launched via `.venv/bin/python -m runtime.server --port 8077` (OpenAI-compatible HTTP), HF_HOME=$PWD/hf_cache.
- Shared runtime NOT plausible/advisable: py3.14 vs mflux 3.12 (torch wheels for 3.14 uncertain), mlx 0.32.0 vs mflux pin <0.33 / installed 0.32.4, system-site-packages leaks, dev checkout not a shipped artifact. Keep a separate Synapse-owned env.
