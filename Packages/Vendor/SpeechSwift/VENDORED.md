Vendored library targets `PersonaPlex`, `HibikiTranslate`, `VoiceChat` (plus their internal deps `AudioCommon`, `MLXCommon`)
from https://github.com/soniqo/speech-swift at b1287a6 (main; latest tag v0.0.29), Apache-2.0, see LICENSE.

Changes:
- Package.swift reduced to those three libraries; dropped every other target (servers, CLIs, benchmarks, other models, tests, docs, examples).
- Dependencies loosened so they resolve alongside Synapse: mlx-swift-lm `from: "3.31.4"` (upstream `exact:`); no hummingbird,
  hummingbird-websocket, swift-websocket, WhisperKit/argmax, MCP, xgrammar, swift-argument-parser, swift-system dependencies.
- SpeechCore (binary xcframework `CSpeechCore`, github.com/soniqo/speech-core releases) is NOT vendored: none of the targets above depend on it.
Sources are otherwise unmodified unless listed below.

Model licenses differ from the code: PersonaPlex weights cc-by-nc-4.0, Hibiki Zero non-commercial, Nemotron VoiceChat openmdw-1.1.

Source patches:
- `PersonaPlex/PersonaPlex.swift`: `fromPretrained` records `modelDirectory` and `modelCacheDirectory()` returns it, so voice presets load from the
  folder passed as `cacheDir:` (upstream recomputes the HF cache path from the model id, i.e. ~/Library/Caches).
- `PersonaPlex/PersonaPlex.swift`: `respondRealtime(... forcedTextToken:, onTextToken:)`, both nil by default: the first supplies a text token
  that replaces the sampled one for a step (Synapse forces spoken tool results into the inner monologue), the second reports each step's text token.
- `PersonaPlex/PersonaPlex.swift`: `respondRealtime(... waitForFullFrames: Bool = false)`; when true the loop waits for a full 80 ms frame in the ring
  buffer instead of padding underruns with silence, giving deterministic push-in / frames-out lock-step. Default behaviour unchanged.
