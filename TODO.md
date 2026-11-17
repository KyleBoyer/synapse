# TODO

New input/output pairings, in the order we plan to build them. Each item moves through: research → build → verify on the 16 GB Mac mini → docs. Check items off as they land and note what was verified.

## Voice cloning (in progress)

Speak in the voice of a short reference clip, from the API and the Audio pane.

- [x] Research: PocketTTS, already Synapse's default voice, clones in FluidAudio (Mimi encoder, 1–10 s clip, no transcript needed). FluidAudio also ships Chatterbox, NeuTTS and LuxTTS backends if quality needs a step up. OpenAI's API shape: `/v1/audio/voice_consents` + `/v1/audio/voices`, then `voice: {"id": "voice_…"}`.
- [x] Engine: `VoiceLibrary` (voices and consents under `<models>/voices/`), `SpeechService.createVoice`, custom-voice synthesis. Verified: clone of a 9.8 s clip in 7.5 s; speaker similarity to the reference 0.54 (stock voice 0.11, same speaker 0.94); output transcribes word for word.
- [x] API: OpenAI's custom voices. `POST/GET/DELETE /v1/audio/voice_consents` (+ rename), `POST /v1/audio/voices` (name, audio_sample, consent; text-prompt voices refused), `DELETE /v1/audio/voices/{id}`, plus `GET /v1/audio/voices`; `voice: {"id": "voice_…"}` on `/v1/audio/speech`. Verified with the official OpenAI SDK against real PocketTTS (`verify-modalities.py --only voices`): consent → clone → speech → transcribed back → deleted.
- [ ] Realtime: custom voices in `/v1/realtime` sessions and Live voice calls
- [ ] App: Audio → Speak takes a reference clip
- [ ] Verify: clone a voice from a fixture clip and check the output by transcribing it back
- [ ] Docs: README, status page, licenses

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
