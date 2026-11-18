# TODO

New input/output pairings, in the order we plan to build them. Each item moves through: research → build → verify on the 16 GB Mac mini → docs. Check items off as they land and note what was verified.

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
- [ ] Record a sample with the microphone in the clone sheet (today it takes a file)
- [ ] Stream the mlx-audio models sentence by sentence (today audio arrives per generated segment)
- [x] Live voice calls with more models: realtime sessions choose the recognizer (`audio.input.transcription.model`: Parakeet EOU streaming, or Whisper / Parakeet v3 per turn through `TurnTranscriber`) and the speech model (`audio.output.model`: any TTS model, stock or cloned voices); Live has a menu for each. Verified: a French call through Parakeet v3 → Qwen3.5 0.8B → VoxCPM2, heard back word for word (VoiceCallModelsE2ETests); RealtimeTests cover the session choices; the OpenAI Realtime SDK check passes.

## Tool calls in voice calls (done)

- [x] Assembled path: session tools go to the chat model; calls come back as `function_call` items with `response.function_call_arguments.delta/done`; `function_call_output` items go back into the conversation (as the `<tool_call>` / `<tool_response>` markup the models write) and the next response speaks the answer.
- [x] Omni path (LFM3): it answers instead of calling tools while speaking, so a short text-only pass decides first (a reply that opens with `<tool_call>` is a call; anything else stops within a few tokens and the turn is spoken).
- [x] Verified with real models and the official Realtime SDK (strict event validation): Qwen3.5 2B + PocketTTS and LFM3 both call `get_weather` for Paris unprompted and speak "18 °C with light rain" after the result. Qwen3.5 0.8B calls tools only with no system prompt.
- [ ] Function tools on Chat Completions and Responses (today only Anthropic Messages takes them)
- [ ] Tools for mlx-vlm and GGUF chat models (their servers' tool support is not wired; only in-process MLX models get tools)
- [ ] MiniCPM-o in the omni path (its whole-reply generation ignores tools)

## Image (+text) embeddings (done)

Image and text in one vector space, for image search and image-to-text matching.

- [x] Research: mlx-swift-lm's embedders are text-only; mlx-embeddings 0.1.0 runs Qwen3-VL-Embedding-2B and SigLIP2 (it also needs mlx-lm and mlx-vlm, undeclared). Probed both: each matches zebra and penguin images to their captions.
- [x] Engine: `ImageTextEmbedder` (mlx-embeddings sidecar) behind the existing embedding backend; `EmbeddingInput` (text, image, or both). Catalog: `qwen3-vl-embedding-2b` (8-bit, 2048 dims, also image+text pairs), `siglip2-so400m` (1152 dims). A shared `PythonSidecar` now carries this and the mlx-audio speech sidecar.
- [x] API: `/v1/embeddings` takes `{"image"}` / `{"text"}` items (Jina's shape); images pick an image model by default; text models refuse them. Verified with the official OpenAI SDK (`verify-modalities.py --only image-embeddings`).
- [x] App: Embed pane takes image documents (add or drop) and an image query; image rows show thumbnails; the reranker is skipped for images with a note; SigLIP2's text/image scale gap is explained when results mix both.
- [x] Verify: EmbeddingE2ETests through Synapse. Qwen3-VL: zebra→"a zebra" 0.48 vs "a penguin" 0.08; penguin→"a penguin" 0.37 vs 0.13; image+text item nearer its image (0.77 vs 0.25). SigLIP2: 0.16 vs 0.05 and 0.15 vs 0.04. App capture: "a striped animal" ranks the zebra first and the penguin last.
- [ ] Video inputs for Qwen3-VL Embedding (the model takes them; Synapse sends text and images only)
- [ ] Token counts for the image models (usage is 0 today)

## Audio → audio

Noise removal, music stem separation, voice conversion.

- [ ] Research models (enhancement, source separation, voice conversion)
- [ ] API shape and pane

## Image → image

Upscaling, background removal, segmentation, depth.

- [ ] Research models
- [ ] API shape and pane

## Video → video

Editing, restyling, upscaling. Heavy on 16 GB; may be Mac Studio only.

- [ ] Research models
- [ ] API shape and pane
