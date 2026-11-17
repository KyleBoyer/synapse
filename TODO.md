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
- [ ] Live voice calls with the mlx-audio models (Live uses PocketTTS)

## Image (+text) embeddings

Image and text in one vector space (CLIP/SigLIP style), for image search and image-to-text matching.

- [ ] Research models with MLX support
- [ ] `POST /v1/embeddings` accepts images; Embed pane compares images and text

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
