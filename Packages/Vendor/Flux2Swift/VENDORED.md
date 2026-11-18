Vendored from https://github.com/VincentGourbin/flux-2-swift-mlx at 315c27e83187909bc5e1f880b4850918342d891b (MIT, see LICENSE).

Changes:
- Package.swift rewritten to the two library targets Synapse uses (FluxTextEncoders, Flux2Core).
  Dropped the CLI/app executables, the optional FluxGemma4VLM target, tests, and the Yams,
  swift-argument-parser and gemma-4-swift-mlx dependencies.
- mlx-swift pin moved from `exact: "0.31.6"` to `.upToNextMinor(from: "0.32.3")` so it resolves with
  mlx-swift-lm 3.32 (upstream pins exactly because mlx-swift breaks API in patch releases; re-verify on bumps).
Sources are otherwise unmodified unless listed below.
- Sources/Flux2Core/Pipeline/Flux2Pipeline.swift: added `try Task.checkCancellation()` after each `onProgress?(...)` call in the denoising loops so Synapse can cancel a running generation. No other source changes (local loading uses the library's `ModelRegistry.setPathOverride` and `kleinEncoderPath`).
