# Image-gen spike findings (2026-11-15)

Scratch pkgs: t_flux (stock flux-2-swift-mlx main), t_fluxfork (path dep on flux2_fork with mlx-swift pin relaxed), t_zimg (z-image-swift main).
Each = Synapse deps (argmax 1.1.1, FluidAudio, hummingbird, multipart-kit, mlx-swift-lm 3.32.3, swift-transformers 1.3.0) + candidate.

## Dependency verdict
- flux-2-swift-mlx @315c27e: FAILS to resolve. `mlx-swift exact: "0.31.6"` vs mlx-swift-lm 3.32.3 needs 0.32.3..<0.33.0.
  Exact error: "root depends on 'mlx-swift-lm' 3.32.3..<4.0.0 and 'flux-2-swift-mlx' depends on 'mlx-swift' 0.31.6."
  Fix: fork, change pin to `.upToNextMinor(from: "0.32.3")`. With that single-line change: resolves (mlx-swift 0.32.3, swift-transformers 1.4.0, swift-huggingface 1.0.0, swift-syntax 603.0.2, gemma-4-swift-mlx 1.9.0, swift-mlx-profiler 1.5.1) AND `swift build --product Flux2Core` compiles all targets (incl. CLI + app) against mlx-swift 0.32.3. Author warns mlx-swift breaks API in patch releases (pin deliberate).
  Extra baggage: Package.swift also depends on gemma-4-swift-mlx (pulls mlx-swift-lm) + swift-mlx-profiler + Yams + argument-parser; our fork would drop the Gemma target/dep.
- z-image-swift @f7c22ed: RESOLVES as-is (mlx-swift 0.32.3, mlx-swift-lm 3.32.3, swift-transformers 1.4.0, mlx-engine-swift 0.74.0, mlx-profiling 0.1.0, mlx-exact-conv-swift 0.1.1). `swift build --product ZImage` OK (150s).
  Caveats: platforms `.macOS(.v26)` (Synapse is .v15 -> must lower in fork or raise Synapse), tools 6.2 (ok). Package-level dep on xocialize/mlx-engine-swift is resolved/fetched even if we only link `ZImage` core (core target has no engine dep; wrapper `MLXZImage` does).

## FLUX.2 klein (Flux2Core)
Products: FluxTextEncoders, Flux2Core, Flux2Chains, FluxGemma4VLM + CLIs/app. tools 6.0, macOS 15. MIT. 32 test files. Last commit 2026-09-12. 5 open issues: #121 klein9B bf16 Metal crash on M1 Max, #126 klein-4b qint8 GPU timeout M5 Pro, #127 wrong memory warning, #119 feature: retainLoadedModels for server use.
Storage: `ModelRegistry.customModelsDirectory: URL?` (default ~/Library/Caches/models); text encoder has SEPARATE `TextEncoderModelDownloader.customModelsDirectory` (must set both) or pass `kleinEncoderPath: URL`. Downloads via HF Hub itself (`hfToken:` for gated 9B). Per-component overrides exist (ModelRegistry OverridableComponent).
API:
  let p = Flux2Pipeline(model: .klein4B /*.klein9B*/, quantization: .balanced /*Flux2QuantizationConfig*/, memoryOptimization: nil, vaeVariant: .smallDecoder, hfToken: nil, kleinEncoderPath: nil)
  try await p.loadModels(progressCallback: { (Double, String) in })   // downloads if missing
  let img: CGImage = try await p.generateTextToImage(prompt:, height:1024, width:1024, steps:50, guidance:4.0, seed: UInt64?, upsamplePrompt:false, onProgress: { (step,total) in })
  let img = try await p.generateImageToImage(prompt:, images:[CGImage] (1-3), height:nil,width:nil, steps:, guidance:, seed:, onProgress:)  // also imageData:[Data] overload
  *WithResult variants return Flux2GenerationResult(image: CGImage, usedPrompt,...)
  Memory: `await p.clearAll()` unloads, `p.keepTextEncoderLoaded`, `memoryProfile`, `clearCacheEveryNSteps`, `estimatedMemoryGB`. Pipeline is a class @unchecked Sendable (not actor) -> we must serialize.
  Klein is distilled: use steps ~4, guidance 1.0 (README sample times 26s 4B / 62s 9B).
Weights (HF tree API):
 - black-forest-labs/FLUX.2-klein-4B: apache-2.0, not gated. Repo 23.7GB total but includes duplicate single-file 7.75GB; needed = transformer 7.75 + text_encoder(Qwen3-4B bf16) 8.05 + vae 0.17.
 - black-forest-labs/FLUX.2-klein-9B: license `other` / flux-non-commercial-license, gated=auto (needs HF token + accept). transformer 18.16 (2 shards 9.8+8.36), text_encoder 16.4, vae 0.17. NON-COMMERCIAL: blocker for a shipped commercial app unless Synapse is free/non-commercial or BFL license obtained.
 - aydin99/FLUX.2-klein-4B-int8 (apache-2.0, community): 8.86GB (transformer 3.88 int8 + text_enc 4.8 + vae). Library's klein4B_8bit variant.
 - Runtime 4/8-bit: on-the-fly quant (qint8, int4, mxfp8/4, nvfp4) from bf16 shards; Klein text encoders also pulled as lmstudio-community/Qwen3-4B-MLX-{4,8}bit (4bit 2.28GB) / Qwen3-8B-MLX-4bit (4.62GB) apache-2.0.
 - black-forest-labs/FLUX.2-small-decoder (apache-2.0, 0.25GB) VAE.
 README memory: Klein4B transformer 7.4/3.9/2.1GB (bf16/8/4bit), 9B 17.3/9.2/4.9.

## Z-Image (z-image-swift)
Products: `ZImage` (core, engine-agnostic) and `MLXZImage` (MLXEngine ModelPackage wrappers; needs mlx-engine-swift - NOT usable directly for us, but core is).
MIT (LICENSE file; GitHub shows NOASSERTION). 2 stars, 19 commits, 2026-07-06..2026-11-09, 0 issues, author xocialize; solo/single-vendor, tests are parity-golden tests (P1-P6) + wrapper tests. README claims GPU-validated: 1024^2 Turbo 8-step ~11-13s on M5 Max, parity cosine>=0.9999999 vs PyTorch.
Download: NOT in core; wrapper delegates to engine's ModelStore. For us: download mlx-community repos ourselves (we already have HF download code) and point at a dir.
Core API (no wrapper) -- mirrors MLXZImage.load():
  let tr = try ZImageWeights.loadTransformer(snapshotPath: dir.path, dtype: .bfloat16); ZImageWeights.quantizeDiT(tr, bits: 4|8)
  let vae = try ZImageWeights.loadVAE(snapshotPath:, dtype: .float32)
  let enc = try ZImageWeights.loadTextEncoder(snapshotPath:, dtype: .bfloat16)
  let tok = try await AutoTokenizer.from(modelFolder: dir/"tokenizer")
  let gen = ZImageGenerator(transformer: tr, vae: vae, textEncoder: ZImageTextEncoder(encoder: enc, tokenizer: tok), schedulerShift:, schedulerDynamic:, transformerDtype: .bfloat16)  // shift read from scheduler/scheduler_config.json (Base 6.0, Turbo 3.0) - see ZImageT2IPackage.readSchedulerConfig (private; copy)
  gen.generate(prompt:, negativePrompt:, width:, height:, steps:8, guidanceScale:0.0, seed: UInt64, onStep: {(i,n) in}) -> (pixels:[UInt8] RGB8, w, h)   // synchronous, blocks; run on dedicated thread; cancellation via Task.isCancelled; ZImageProgress.$sink task-local for phases
  gen.generateImg2Img(prompt:, negativePrompt:, image: MLXArray [1,3,H,W] in [-1,1], width:, height:, steps:, guidanceScale:, strength: 0.75, seed:)   // strength img2img, NOT instruction editing
  Unload: drop generator ref + MLX.Memory.clearCache(). Quant: bf16 | int8 (DiT 6.4GB) | int4 (DiT 3.5GB), quantize-on-load from bf16 (full 12GB shard download regardless).
  Size: multiples of 16, area cap 1536^2 (maxOutputPixels). Defaults Turbo: 8 steps, guidance 0. Base: ~28 steps, CFG 4.0 + negative prompt.
  PNG encode: not in core; we do CGImage from pixels.
Weights: mlx-community/Z-Image-Turbo-bf16 (apache-2.0) 20.54GB (transformer 12.3 in 3 shards, text_encoder Qwen3-4B 8.05, vae 0.17); mlx-community/Z-Image-bf16 (Base, apache-2.0) 20.54GB (transformer 12.3). Upstream Tongyi-MAI/Z-Image-Turbo 32.9GB (fp32 transformer), Tongyi-MAI/Z-Image 20.55GB, both apache-2.0 ungated. Z-Image Base IS available. Also NitroFusion2 tier (ChenDY/NitroFusion2, 1-4 steps).
Embeds a text encoder and tokenizer in the same snapshot; layout is diffusers-style dirs transformer/ text_encoder/ vae/ tokenizer/ scheduler/.

## Other Qwen-Image Swift/MLX
- xocialize/qwen-image-edit-swift (Qwen-Image-Edit-2511 imageEdit; same author/stack; mlx-swift 0.32.3, mlx-swift-lm 3.32.3, mlx-engine-swift >=0.68; license NOASSERTION/other - check), xocialize/qwen-image21-swift (Qwen-Image-2.1 7B), qwen25vl-mlx-swift (VL encoder), mlx-vosr-swift. All 1-2 stars, Oct-Nov 2026.
- rinste/turbo-mlx (MIT, 180 stars, 2026-11-03): native macOS app on MLX Swift, image+video gen; app not library.
- IIMrFreemanII/AIStudio: macOS node graph app, Qwen-Image 2.1 (C language flag, 0 stars).
Instruction-editing: Klein supports multi-reference editing natively (generateImageToImage); Z-Image only strength img2img.
