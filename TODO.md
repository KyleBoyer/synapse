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
- [ ] MiniCPM-o in the omni path (its whole-reply generation ignores tools)

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
- [ ] Voice conversion: wait for a model in mlx-audio or FluidAudio

## Image → image

Upscaling, background removal, segmentation, depth.

- [x] Research: background removal and subject masks are built into macOS Vision (`VNGenerateForegroundInstanceMaskRequest`, no download); depth from Apple's Core ML Depth Anything V2 small (`apple/coreml-depth-anything-v2-small`); BRIA RMBG 2.0 is non-commercial. No Core ML or MLX Real-ESRGAN is published; upscaling would need a conversion or a diffusion upscaler (Qwen-Image-Edit LoRAs, heavy).
- [x] Background removal and subject masks (Vision): `POST /v1/images/cutout` and Images → Cut Out. Verified: the zebra lifted in 0.43 s on a transparent background (48% coverage), mask at input size; SDK check passes.
- [x] Depth maps (Depth Anything V2 small, Core ML, 50 MB): `POST /v1/images/depth` and Images → Depth. Verified: the zebra is near (0.52) and the sky far (0.01), 0.2 s per image warm; app capture in light mode.
- [ ] Upscaling: pick an approach

## Video → video

Editing, restyling, upscaling. Heavy on 16 GB; may be Mac Studio only.

- [ ] Research models
- [ ] API shape and pane
