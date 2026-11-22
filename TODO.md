# TODO

New input/output pairings, in the order we plan to build them. Each item moves through: research → build → verify on the 16 GB Mac mini → docs. Check items off as they land and note what was verified.

## Built-in tools (done)

Tools Synapse runs itself during a chat, as OpenAI's hosted tools and Anthropic's server tools do.

- [x] One tool loop for Responses, Chat Completions and Messages: the model calls a built-in, Synapse runs it, the result goes back, until the model answers or calls a client tool (5 turns, set in the app).
- [x] `web_search` with DuckDuckGo (no key), Brave Search, Tavily or SearXNG; `image_generation` beside other tools and on every chat API (markdown image on Chat Completions); `synapse` tools: time, installed models, loaded models and memory.
- [x] Server → Built-in tools: provider and key, results per search, image model and size, tools every chat gets, turns per answer.
- [x] Verified with the OpenAI and Anthropic SDKs (`verify-modalities.py --only server-tools`): Qwen3.5 2B passes all, image included; Inkling 2 Mini passes the time, models and Messages search checks and calls web_search on Responses, where DuckDuckGo started answering 202 (its limit for an address that searches a lot).
- [x] Fixed on the way: a tool call the strict parser refused vanished from the reply (now read leniently or passed through as text); Inkling looped on empty thinking blocks when offered tools with a zero thinking budget; llama.cpp gets tool history as tool_calls and tool messages.
- [ ] Partial images when image_generation runs beside other tools (only the image-only Responses path streams them).
- [ ] Built-in calls a model makes in the same turn as a client call are dropped.

## Running models (done)

Make repeat requests fast and give clients the knobs the engines already have.

- [x] Prompt cache, in-process MLX: checkpoints at the end of the history (before the generation prompt), so reuse works on Qwen3.5's unrewindable linear attention; Qwen's rope state travels with each. Verified on Qwen3.5 0.8B: replies identical to uncached; turn-2 time to first token 1.07 s → 0.11 s (2,309 of 2,334 tokens reused).
- [x] Disk tier: histories ≥ 1,024 tokens saved under `<models>/cache`, rewritten only when a conversation grows by a third. Verified: after unload, turn 2 reuses 2,309 tokens from disk with identical output; across an app relaunch too.
- [x] llama.cpp (slot cache, `--cache-ram`) and mlx-vlm (APC, on only with 32 GB or more: under load on 16 GB it refused requests even after a retry). Verified: GGUF Llama 3.2 1B reuses 1,684 of 1,697; Gemma 3n 1,996 of 2,017 (2.3 s → 0.11 s prefill) when it was on, same reply as cold.
- [x] Cached tokens in every API's usage (OpenAI SDK and Anthropic SDK checked: `verify-modalities.py --only cache`).
- [x] KV precision Full/8-bit/4-bit on MLX, llama.cpp and mlx-vlm. Verified: 8-bit cached = uncached output; Qwen3.5 0.8B checkpoint 48 → 35 MB. TurboQuant left out (its cache has no `copy()`).
- [x] Speculative decoding with a draft model, full-attention pairs only (mlx-swift-lm needs trimmable caches; Qwen3.5 has none and its 4-bit weights ship no MTP heads). Verified: Llama 3.2 3B + 1B draft, 50 → 69 tok/s over 3 alternating runs, identical text.
- [x] Sampling: seed, top_k, min_p, presence/frequency/repetition penalties on every route and engine. Verified: same seed, same text on MLX, GGUF and mlx-vlm.
- [x] Thinking budget from reasoning effort / `budget_tokens`. Verified: a 64-token budget stops thinking at ~64 tokens; small Qwen3.5 models often keep reasoning after the forced `</think>` (README says so).
- [x] Keep loaded (pinned models), measured resident memory (the sidebar no longer sums download sizes), model card Running section with prompt-cache metrics from every request, Memory pane cache rows, Settings → Running models.
- [ ] Prompt cache for requests with images, video or audio (mlx's appendMediaSuffix path).
- [ ] Acceptance rate for draft-model speculation (mlx-swift-lm reports it only for MTP).

## Every modality into every other (done)

- [x] Send To on every result (images, tool results, clips, transformed videos, audio clips, chat replies, transcripts, call transcripts): direct where a model takes the input (image → video start, video frame → image edit, video soundtrack → Clean Up), through editable text otherwise (audio → transcript → image). Each handoff checked in the app; Chat switches to an omni model when audio arrives.
- [x] Audio tabs: Sound & Music (first, default), Speech, Clean Up.
- [x] More sound models: Stable Audio 3 Medium (10 s of jungle ambience in 8 s) and MiniMax Music 3 4-bit (songs with sung lyrics; a 20 s song in 6 min, lyrics transcribe back word for word). `lyrics` on `/v1/audio/generations` and a Lyrics field for MiniMax.
- [ ] Real image-to-video and frame-to-video runs: LTX-2.3 is not on the 16 GB Mac; checked with the mock engine.

## Saved history (done)

- [x] Chats, images, image tools, video and transforms, speech/sound/cleanup clips, Live call transcripts, GUI transcriptions and Embed comparisons kept in `~/Library/Application Support/Synapse/History`; delete per item, per pane, or all; retention in Settings. API requests are never saved (a unit test guards it). Verified in the app: GUI chat and image restored after relaunch; API chat and image sent alongside not saved.
- [ ] Older items beyond the newest 50 per gallery pane load on demand.

## Voice cloning (done)

Speak in the voice of a short reference clip, from the API and the Audio pane.

- [x] Research: PocketTTS, already Synapse's default voice, clones in FluidAudio (Mimi encoder, 1–10 s clip, no transcript needed). FluidAudio also ships Chatterbox, NeuTTS and LuxTTS backends if quality needs a step up. OpenAI's API shape: `/v1/audio/voice_consents` + `/v1/audio/voices`, then `voice: {"id": "voice_…"}`.
- [x] Engine: `VoiceLibrary` (voices and consents under `<models>/voices/`), `SpeechService.createVoice`, custom-voice synthesis. Verified: clone of a 9.8 s clip in 7.5 s; speaker similarity to the reference 0.54 (stock voice 0.11, same speaker 0.94); output transcribes word for word.
- [x] API: OpenAI's custom voices. `POST/GET/DELETE /v1/audio/voice_consents` (+ rename), `POST /v1/audio/voices` (name, audio_sample, consent; text-prompt voices refused), `DELETE /v1/audio/voices/{id}`, plus `GET /v1/audio/voices`; `voice: {"id": "voice_…"}` on `/v1/audio/speech`. Verified with the official OpenAI SDK against real PocketTTS (`verify-modalities.py --only voices`): consent → clone → speech → transcribed back → deleted.
- [x] Realtime: the shared PocketTTS lease speaks `voice_…` ids, so `/v1/realtime` sessions (`session.audio.output.voice`) and Live voice calls use cloned voices; Live's voice field is now a menu with them. Verified: speech through the shared TTS scores 0.54 similarity to the reference (stock voice 0.06). The Live menu was built but not captured.
- [x] App: Audio → Speak → Clone Voice… (choose or drop a clip, name it, confirm permission); cloned voices join the Voice menu and a Custom voices panel with delete. Verified in the app: a 7.3 s clip cloned, then spoke with first audio in 0.38 s at 2.6× realtime.
- [x] Verify: VoiceCloneE2ETests (speaker similarity and transcription) and the SDK run above.
- [x] Docs: README routes and example. Notices unchanged (FluidAudio was already listed).
- [x] More models: voices are model-independent now (the clip and its transcript are kept; PocketTTS derives its conditioning on first use). Added Qwen3-TTS 1.7B, VoxCPM2 and Chatterbox Turbo through an mlx-audio sidecar. Verified through Synapse with one cloned voice: similarity Qwen3-TTS 0.85, VoxCPM2 0.80, Chatterbox Turbo 0.63, PocketTTS 0.54; each heard back word for word. Tried and left out: LuxTTS (0.61, slower than realtime) and StyleTTS2 (crashed in FluidAudio's synthesizer).
- [x] Consent dropped: voices need no consent (the consent routes stay for OpenAI clients that call them); the app's permission box is gone.
- [x] Record a sample with the microphone in the clone sheet: Record captures up to 10 s (24 kHz WAV) and stops on its own or with Stop. Verified in the app: a 10.0 s recording became the sample and enabled Clone Voice.
- [x] Stream the mlx-audio models sentence by sentence: the sidecar splits the text and generates per sentence. Verified (warm): VoxCPM2 first audio at 4.1 s of 11.1 s, Chatterbox Turbo at 0.9 s of 2.7 s, three chunks each (VoiceCloneE2ETests).
- [x] Live voice calls with more models: realtime sessions choose the recognizer (`audio.input.transcription.model`: Parakeet EOU streaming, or Whisper / Parakeet v3 per turn through `TurnTranscriber`) and the speech model (`audio.output.model`: any TTS model, stock or cloned voices); Live has a menu for each. Verified: a French call through Parakeet v3 → Qwen3.5 0.8B → VoxCPM2, heard back word for word (VoiceCallModelsE2ETests); RealtimeTests cover the session choices; the OpenAI Realtime SDK check passes.

## Tool calls everywhere (done)

- [x] Assembled path: session tools go to the chat model; calls come back as `function_call` items with `response.function_call_arguments.delta/done`; `function_call_output` items go back into the conversation (as the `<tool_call>` / `<tool_response>` markup the models write) and the next response speaks the answer.
- [x] Omni path (LFM3): it answers instead of calling tools while speaking, so a short text-only pass decides first (a reply that opens with `<tool_call>` is a call; anything else stops within a few tokens and the turn is spoken).
- [x] Verified with real models and the official Realtime SDK (strict event validation): Qwen3.5 2B + PocketTTS and LFM3 both call `get_weather` for Paris unprompted and speak "18 °C with light rain" after the result. Qwen3.5 0.8B calls tools only with no system prompt.
- [x] Function tools on Chat Completions (tool_calls, tool messages, streamed deltas) and Responses (function_call items and events, function_call_output inputs), and for spoken Chat Completions replies (tool_calls with audio null).
- [x] Tools for mlx-vlm and GGUF chat models: requests carry `tools` and the servers' streamed `tool_calls` are assembled.
- [x] Verified across input and output types with real models and the official SDKs (`verify-modalities.py --only tools`, `verify-openai-realtime.py`): text, image, video (Qwen3.5 2B), audio in (Gemma 4 E2B, LFM3), spoken replies (Qwen3.5 2B + TTS, LFM3's own voice), a GGUF model (Llama 3.2 1B), Responses, and a realtime call that sees a camera frame then calls record_animal("zebra").
- [x] MiniCPM-o in the omni path: a text-only pass decides first (Qwen-style `<tool_call>` JSON, after any `<think>`), as LFM3's does; follow-up answers now carry the caller's last utterance even after a tool result (MiniCPM-o speaks in that voice and failed without it). Verified (VoiceCallToolsE2ETests, spoken question): get_weather for Paris after 10.3 s, then "It's 18°C in Paris, with light rain currently falling" in 6.9 s of speech; LFM3 still passes.
- [x] GGUF vision: the projector (mmproj) is fetched and passed to llama.cpp. Verified: Gemma 3 4B Q4_K_M answers "Zebra" about zebra.jpg in 5.3 s (CustomModelE2ETests).

## Tool calls in full-duplex calls

Both full-duplex families take session tools. VoiceChat calls them itself on its function channel; PersonaPlex has no tool head, so a small chat model (`session.tools_model`) decides calls from the transcript and its answer is forced into PersonaPlex's inner monologue, which the model then speaks in its own voice. `response.create` is a no-op in these calls (the model decides when to talk).

- [x] VoiceChat: session tools go into its tool-calling system prompt; its function channel becomes `function_call` items and `function_call_output` goes back through `injectFunctionResponse`. Verified with the official Realtime SDK (`verify-openai-realtime.py --duplex-only`): `voicechat-11b-int5` calls get_weather for Paris on its own and says "In Paris right now, it is eighteen degrees with light rain". The int8 build stalls on 16 GB (88 minutes paging without finishing one exchange); int5 (8.6 GB, added) runs at about 4.4× slower than real time here, so int8 is for the Mac Studio.
- [x] PersonaPlex: a tools model (`session.tools_model`, Qwen3.5 2B verified) reads each finished user turn with a decide-only instruction and calls the tool; after the result it writes one sentence, which is forced into PersonaPlex's inner monologue so PersonaPlex says it in its own voice. Verified with the official Realtime SDK: get_weather for Paris, then "The weather in Paris right now is 18…" spoken by PersonaPlex. Given the call's voice-assistant instructions instead, Qwen3.5 2B answered the question itself, hence the decision instruction.

## Image (+text) embeddings (done)

Image and text in one vector space, for image search and image-to-text matching.

- [x] Research: mlx-swift-lm's embedders are text-only; mlx-embeddings 0.1.0 runs Qwen3-VL-Embedding-2B and SigLIP2 (it also needs mlx-lm and mlx-vlm, undeclared). Probed both: each matches zebra and penguin images to their captions.
- [x] Engine: `ImageTextEmbedder` (mlx-embeddings sidecar) behind the existing embedding backend; `EmbeddingInput` (text, image, or both). Catalog: `qwen3-vl-embedding-2b` (8-bit, 2048 dims, also image+text pairs), `siglip2-so400m` (1152 dims). A shared `PythonSidecar` now carries this and the mlx-audio speech sidecar.
- [x] API: `/v1/embeddings` takes `{"image"}` / `{"text"}` items (Jina's shape); images pick an image model by default; text models refuse them. Verified with the official OpenAI SDK (`verify-modalities.py --only image-embeddings`).
- [x] App: Embed pane takes image documents (add or drop) and an image query; image rows show thumbnails; the reranker is skipped for images with a note; SigLIP2's text/image scale gap is explained when results mix both.
- [x] Verify: EmbeddingE2ETests through Synapse. Qwen3-VL: zebra→"a zebra" 0.48 vs "a penguin" 0.08; penguin→"a penguin" 0.37 vs 0.13; image+text item nearer its image (0.77 vs 0.25). SigLIP2: 0.16 vs 0.05 and 0.15 vs 0.04. App capture: "a striped animal" ranks the zebra first and the penguin last.
- [x] Video inputs for Qwen3-VL Embedding: `{"video": …}` items (MP4/MOV data or http URL) are embedded from 8 evenly spaced frames (mlx-embeddings 0.1.0 turns Qwen3-VL's own video processor off). Verified: zebra.mp4 → "a zebra" 0.63, "a penguin" 0.18, with the official SDK too.
- [x] Token counts for the image models: Qwen3-VL from its attention mask, SigLIP2 from its tokenizer plus 729 patches per image. Verified: usage 585 / 1184 tokens in EmbeddingE2ETests and through the SDK.

## Audio → audio

Noise removal, music stem separation, voice conversion.

- [x] Research: mlx-audio 0.6.6 (already Synapse's speech runtime) has speech enhancement (DeepFilterNet 30 MB, NemotronLabs RE-USE 40 MB, MossFormer2 SE 48 kHz 570 MB), text-prompted source separation (SAM-Audio small 2.4 GB / base 5 GB / large 12 GB), vocal/instrumental stems (Mel-RoFormer), and two-speaker separation with restoration (DialogueSidon, 0.9 GB bf16). No voice conversion model in this release.
- [x] Enhance: `POST /v1/audio/enhance` with DeepFilterNet 3 (default) and NemotronLabs RE-USE. Verified: steady noise under speech drops 51 dB (DeepFilterNet, 1.2 s) and 45 dB (RE-USE, 6.6 s), words heard back intact (AudioEditE2ETests, and with the official SDK).
- [x] Separate: `POST /v1/audio/separate` returns named tracks: SAM-Audio small with a `prompt` (`target`, `residual`), DialogueSidon without one (`speaker_1`, `speaker_2`). Verified: SAM-Audio pulls speech out from under a loud tone (19 s); DialogueSidon gives each of two speakers their own track, word for word. Mel-RoFormer left out (no `generate()` in mlx-audio 0.6.6; SAM-Audio with "vocals" covers stems).
- [x] Pane: Audio → Clean Up (choose or drop a recording; a prompt field appears for SAM-Audio; each track is a playable, saveable clip). Verified in the app with DeepFilterNet.
- [x] Voice conversion: Chatterbox Turbo's speech tokenizer and S3Gen decoder (what upstream ChatterboxVC does) in the mlx-audio sidecar; `POST /v1/audio/convert` (a recording plus a cloned voice id) and Audio → Clean Up with Chatterbox Turbo and a Voice menu. Verified: Samantha's recording as Daniel's cloned voice in 3.7 s for 3.4 s of audio; speaker similarity to Daniel 0.43, to Samantha 0.10; words heard back; the SDK check passes; app capture.

## Image → image

Upscaling, background removal, segmentation, depth.

- [x] Research: background removal and subject masks are built into macOS Vision (`VNGenerateForegroundInstanceMaskRequest`, no download); depth from Apple's Core ML Depth Anything V2 small (`apple/coreml-depth-anything-v2-small`); BRIA RMBG 2.0 is non-commercial; mlx-community publishes Real-ESRGAN weights for MLX.
- [x] Background removal and subject masks (Vision): `POST /v1/images/cutout` and Images → Cut Out. Verified: the zebra lifted in 0.43 s on a transparent background (48% coverage), mask at input size; SDK check passes.
- [x] Depth maps (Depth Anything V2 small, Core ML, 50 MB): `POST /v1/images/depth` and Images → Depth. Verified: the zebra is near (0.52) and the sky far (0.01), 0.2 s per image warm; app capture in light mode.
- [x] Upscaling: Real-ESRGAN x4plus (mlx-community's MLX weights, 33 MB) as functional MLX in Swift, tiled; `POST /v1/images/upscale` and Images → Upscale. Verified: 448 → 1792 px in 6.4 s, shrinking it back is within 1.7% of the input, and a close crop is sharp where bicubic is soft; app capture.

## Video → video

Editing, restyling, upscaling. Heavy on 16 GB; may be Mac Studio only.

- [x] Research: frame-by-frame tools reuse the image models (depth, Vision masks, Real-ESRGAN; mlx-community's compact general-x4v3 is about ten times faster than x4plus). Restyling needs a video diffusion model (LTX-2 IC-LoRAs), heavy enough to be Mac Studio work.
- [x] Frame by frame: `POST /v1/videos/transform` (`depth`, `mask`, `upscale`) and Video → Transform; H.264 at the source's frame timing, the source's sound passed through. Verified on zebra.mp4 with sound: mask (Vision) 20 frames in 0.7 s, depth 1.2 s, ×4 to 1280 px with general-x4v3 in 12 s; same frame count, duration and sound (VideoTransformTests, ImageToolsE2ETests); app captures.
- [ ] Restyle with LTX-2 (video to video with a prompt): Mac Studio

## More video and music models (done)

- [x] Wan 2.2 TI2V 5B (`Anes1032/Wan2.2-TI2V-5B-mlx-q8`, Apache-2.0) through mlx-video's Wan pipeline (same pinned commit as LTX). Its UMT5 tokenizer is fetched beside the model and a wrapper points the pipeline at it, so runs stay offline. The auto VAE tiling ran out of GPU memory on 16 GB after an 18-minute denoise; aggressive tiling (256 px, 32 frames) decodes. Verified over `/v1/videos`: a 4 s 768x512 fox in snow in 66 minutes on the 16 GB M4.
- [x] ACE-Step 1.5 4-bit (MIT) through its own runtime pinned to mlx-audio's unreleased `pc/add-ace` merge (1e8264a48). Verified over `/v1/audio/generations`: 30 s of 48 kHz stereo in 18 s. Instrumental only: its 5 Hz planning LM plans a full-length song whatever duration is asked, and with or without it no sung lyrics came through (empty transcripts with Parakeet and Whisper, no vocal track from SAM-Audio), where MiniMax Music 3's lyrics transcribe back.
- [x] MiniMax H3 through stable-diffusion.cpp (prebuilt CLI `master-1106-532d2c1`, sha256-pinned, fetched on first use), plus LoRA add-ons: `ModelSpec.baseModel` marks a patch, it downloads on its own and is applied per clip (`VideoRequest.lora`, the Video pane's LoRA menu, `lora` on `/v1/videos`). The int8 4B text encoder crashes in Metal, so it runs on the CPU. Verified on the 16 GB M4: base + Turbo 4-step LoRA, 1.6 s 480x288 with sound in about 13 minutes.
- [ ] MiniMax H3 large set (4-bit transformer, 32B encoder, 43 GB) on a 64 GB+ Mac. Not yet run.
- [x] LoRAs from Hugging Face, with strengths and stacking: Add from Hugging Face recognizes LoRA repos (no config.json) and adds one file at a time as an add-on (`CustomModel.baseModel`, id `org/repo/path`, own folder under `loras/`). Video lists a base's LoRAs with a checkbox and a strength slider each; `/v1/videos` takes `loras: [{id, strength}]` or `lora` + `lora_strength`. Each LoRA's tensor names are checked against H3's weights before the run (sd.cpp skips unmatched tensors silently at run time); Sentinel7/h3's kohya and ComfyUI files match 100%, checked with sd.cpp's own name conversion. Unlisted downloaded LoRAs are adopted at launch.
- [x] Inkling 2 Mini (Thinking Machines, Apache-2.0) as a GGUF chat model with image input. llama.cpp is pinned to master commit 690b87d: the looped layers need ggml-org/llama.cpp#32704 (merged 2026-11-21, in no b-tag yet). Under 32 GB, ModelPrep requantizes ggml-org's IQ4_NL with the bundled llama-quantize (IQ2_S gate/up experts, IQ4_NL down experts, 11.6 GB). Verified on the 16 GB M4 through the store, prep and chat: "Paris", "Zebra" from the zebra fixture, about 16 tokens/s. Context is 4,096 tokens there (llama.cpp's `--fit`). Move back to a b-tag once one includes #32704.
- [x] GGUF LoRAs on a built-in base: a GGUF repo whose card names Inkling 2 Mini offers its LoRA files, which run on `inkling-2-mini` through `--lora` (`CustomModel.baseModel` on a `.gguf` model). AtomicChat's uncensoring LoRA verified on the 16 GB M4: answers the lock-picking probe the base refuses, "Paris", "Zebra", same speed.
- [x] `synapse` command-line tool (`Contents/Helpers/synapse`): `models list|add|delete` for your own models through the running app (`/v1/synapse/models`, loopback only). Verified against the running app: add with `--wait`, list, delete.
- [ ] Not added, each needs a new runtime: LTX-2.5 (MLX build has a ~25 GB memory floor), YuE2-3B (Swift port; CC BY-NC), MusicGen (mlx-audiogen; CC BY-NC), CogVideoX-Fun 5B.

## Shipping (done)

- [x] Public repo at github.com/KyleBoyer/synapse; history scanned for secrets (gitleaks, clean).
- [x] CI on every push (build + unit tests on macos-26) and a Release workflow (bump none/patch/minor/major).
- [x] v0.1.1: Developer ID signed, notarized and stapled; Gatekeeper reports "Notarized Developer ID".
- [x] v0.1.2: Sparkle updates (appcast.xml on each release, EdDSA-signed) and a drag-to-Applications DMG; earlier releases removed so every published build can update itself.
- [x] v0.1.3: the DMG opens on a drawn background with an arrow from Synapse to Applications (dmgbuild, scripts/dmg).
- [x] v0.1.4: prompt caching, KV precision, speculative decoding, sampling controls, thinking budget, keep-warm, measured memory, cache metrics on model cards, saved history. DMG and app "Notarized Developer ID"; appcast offers build 5.
- [x] v0.1.5: Edit / Animate / Continue / Transform / Clean Up feed each result into the next generation; no Dock icon while the window is closed (Synapse stays in the menu bar). DMG and app "Notarized Developer ID"; appcast offers build 6.
- [x] v0.1.6: Send To between every modality, Audio tabs Sound & Music / Speech / Clean Up, Stable Audio 3 Medium and MiniMax Music 3 with lyrics. DMG and app "Notarized Developer ID"; appcast offers build 7.
- [x] v0.1.7: Live mic/speaker pickers and one shared audio link, full-duplex phrase playback and transcripts, mic-off and MLX cache crash fixes, Wan 2.2 TI2V 5B video, ACE-Step 1.5 instrumental music, sidecar output read in order. Appcast offers build 8.
- [x] App icon is an Icon Composer `.icon`, so macOS 26 no longer draws it inside a grey plate.
- [x] README rebuilt around real screenshots from the 16 GB Mac mini (docs/screenshots).
