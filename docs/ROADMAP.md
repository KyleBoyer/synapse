# Synapse roadmap: images, realtime, model manager, vOOM

Status as of 2026-11-15. The development machine is an M4 with 16 GB; the target is a Mac Studio with 128 GB.
On 16 GB, oversized models are expected to swap. The goal there is to confirm each model family's happy path, not speed.

## Decisions

| Area | Decision | Why |
|---|---|---|
| Model memory | One `ModelManager` for every model kind: budget (default 75% of RAM), LRU eviction of idle models, idle unload (15 min), leases so nothing unloads mid-request, overcommit allowed and reported | Chat, image, ASR and TTS models must coexist; a voice call needs three at once |
| FLUX.2 klein 4B/9B | Native Swift via a vendored copy of `flux-2-swift-mlx` (MIT) with its `mlx-swift` pin bumped to 0.32.x | Upstream pins `mlx-swift` exactly 0.31.6, which conflicts with `mlx-swift-lm` 3.32 |
| Z-Image / Z-Image Turbo | Native Swift via a vendored `ZImage` core target from `z-image-swift`; Synapse downloads weights itself | The wrapper depends on the author's engine; the core resolves cleanly |
| Qwen-Image | Python `mflux` sidecar (pinned 0.24.0) in an isolated `uv` environment installed on first use; JSON lines over stdio | No usable Swift port; mflux is the mature MLX implementation |
| Realtime transport | OpenAI Realtime API (GA event names) over WebSocket at `/v1/realtime` with `hummingbird-websocket` 2.8 | Clients (OpenAI SDK, Agents SDK, LiveKit) speak it; resolves with our Hummingbird |
| Live transcription / translation / cascaded calls | FluidAudio: streaming Parakeet (EOU for English, sliding-window TDT v3 multilingual), Silero VAD, PocketTTS streaming or Kokoro; Qwen3.5 for replies and translation | Already a dependency; no new packages |
| Full duplex | Vendored `speech-swift` (Apache-2.0) with five pin fixes: VoiceChat 11B first, then PersonaPlex 7B; Hibiki Zero per utterance | Upstream pins conflict; Hibiki's streaming API is not real streaming yet |
| vOOM | Phase 1: optional sidecar runtime that Synapse proxies to for oversized chat models. Phase 2: image generation with weight paging added to vOOM itself under vOOM's rules | vOOM is a 118k-line Python research runtime that assumes it owns the machine; porting first would be premature |
| Model storage | Configurable models folder (`Settings.modelsFolder`) | Image and duplex weights are tens of GB |

Licenses shown in the app: FLUX.2 klein 9B (non-commercial, gated), Qwen-Image 2.1 (Qwen Research License), PersonaPlex and Hibiki (non-commercial). Everything else listed is Apache-2.0 or MIT.

## Phases and checks

Each phase ends in a check run against real weights; the check names the model family it proves.

1. **Model manager** (done): unit tests for reuse, LRU, leases, overcommit, shared concurrent load, idle reaping; transcription and chat migrated.
2. **Image API**: `/v1/images/generations`, `/v1/images/edits` (b64 and url, streaming partial images), Responses `image_generation` tool with Qwen3.5 choosing the prompt. Check: OpenAI SDK strict schema validation of every response and SSE event, like `scripts/verify-openai-api.py`.
3. **Image engines**, one happy path per family through the API:
   - FLUX.2 klein 4B text-to-image and reference-image edit.
   - Z-Image Turbo text-to-image.
   - Qwen-Image 2.1 q4 text-to-image via mflux (Qwen-Image 2512 and Edit 2511 deferred to the 128 GB machine).
   - FLUX.2 klein 9B needs a Hugging Face token; verify on the Studio.
4. **Realtime**: WebSocket session types `transcription`, `realtime` (cascaded voice), translation via instructions, and an experimental duplex model id. Check: official `openai` SDK `client.realtime.connect` against synthesized speech fixtures (transcript text, spoken reply audio, barge-in cancels a response).
5. **Live pane** in the app: mic capture, captions, translation, voice call.
6. **vOOM sidecar**: launch, readiness, proxy `/v1/chat/completions` and `/v1/responses`, unload Synapse models first. Check: a vOOM-served model answers through Synapse's API.
7. **vOOM image generation with paging** (in the vOOM repo, following its CLAUDE.md gates): Z-Image first, then FLUX.2, then Qwen-Image.
