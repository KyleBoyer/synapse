Vendored core target `ZImage` from https://github.com/xocialize/z-image-swift at f7c22ed92ac4e35dab0f9c110812f2dfa981150f (MIT, see LICENSE).

Changes:
- Package.swift reduced to the `ZImage` library; dropped the MLXZImage engine wrapper, CLI and tests
  (and with them the mlx-engine-swift dependency). Synapse downloads weights itself.
- Platform lowered from macOS 26 to macOS 15; mlx-swift pinned `.upToNextMinor(from: "0.32.3")`;
  mlx-swift-lm traits disabled (the FoundationModels bridge needs the macOS 27 SDK).
Sources are otherwise unmodified unless listed below.
