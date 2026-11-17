# Synapse

Synapse is a native macOS app that transcribes audio and video into subtitles using local models. Nothing leaves your Mac. It runs Whisper (via WhisperKit) and NVIDIA Parakeet (via FluidAudio) on Core ML, and exposes an HTTP API that is compatible with the OpenAI transcription API and with Bazarr's Whisper provider. It can also watch folders and write subtitle files next to your media. It also runs Qwen3.5 chat and vision models (0.8B, 2B, 4B, 9B) on MLX, served through OpenAI-compatible Chat Completions and Responses endpoints and the Anthropic Messages API, so either SDK works.

## Requirements

- Apple Silicon Mac
- macOS 26 or later

## Install

1. Download the latest `Synapse-<version>.zip` from the Releases page and unzip it.
2. Move `Synapse.app` to `/Applications`.
3. If the release is not notarized (the release notes say "Unsigned build"), macOS will block it. Run `xattr -dr com.apple.quarantine /Applications/Synapse.app`, or right-click the app and choose Open.
4. Open the Models tab and download a model.

If you enable "Allow LAN" in the Server tab, the server binds to `0.0.0.0` and macOS shows an "Allow incoming connections?" firewall prompt. With ad-hoc signed builds the prompt can reappear after each update.

## Build from source

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # MLX compiles Metal shaders
scripts/build-ffmpeg.sh      # builds vendor/ffmpeg/bin/ffmpeg (LGPL, ~minutes)
xcodegen generate
open Synapse.xcodeproj
```

Core logic tests: `cd Packages/SynapseCore && swift test`. End-to-end tests download real models and only run with `SYNAPSE_E2E=1`. Xcode 26 is required.

MLX needs a compiled Metal library, which `swift build` cannot produce. `scripts/test-chat-e2e.sh` builds it once with xcodebuild, puts it next to the test binary, and runs the Qwen tests (downloads `qwen3.5-0.8b`, about 650 MB).

With the app running and `qwen3.5-0.8b` downloaded, `scripts/verify-openai-api.py` checks the chat endpoints with the official OpenAI Python SDK (`pip install openai`). It validates every response and stream event against the SDK's types. `scripts/verify-anthropic-api.py` does the same for the Messages API with the official Anthropic Python SDK (`pip install anthropic`).

## HTTP API

Default address is `http://127.0.0.1:9000`. The port and LAN access are set in the Server tab. With LAN off, no key is needed. With LAN on, every route except `/health` needs the API key, sent as `Authorization: Bearer <key>`, as `x-api-key: <key>`, or as a path prefix `/k/<key>/...`. Errors use `{"type":"error","error":{"message":"...","type":"invalid_request_error"}}`, which both OpenAI and Anthropic clients read.

| Method and path | Input | Output |
|---|---|---|
| `GET /health` | none | `{"status":"ok","version":"0.1.0"}` |
| `GET /v1/models` | none | list of downloaded models, with the fields of both OpenAI and Anthropic model objects |
| `POST /v1/audio/transcriptions` | multipart: `file`, `model`, `language`, `response_format` (default `json`; also `diarized_json`), `diarize` (`true` labels speakers); `prompt`, `temperature`, `timestamp_granularities[]` are ignored. `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` mean the default model; `gpt-4o-transcribe-diarize` also labels speakers | transcript in the requested format; with speakers, SRT lines start with `A: `, WebVTT uses `<v Speaker A>` |
| `POST /v1/audio/translations` | same, translates to English | same |
| `POST /asr` | query: `task`, `language`, `output` (txt, vtt, srt, tsv, json; default `txt`), `encode` (default `true`); multipart: `audio_file`. `word_timestamps`, `vad_filter`, `initial_prompt`, `video_file` are ignored | rendered format as `text/plain` with `Content-Disposition` and `Asr-Engine: synapse` |
| `POST /detect-language` | query: `encode`; multipart: `audio_file` | `{"detected_language":"english","language_code":"en","confidence":0.97}`; `und` if no multilingual Whisper model is downloaded |
| `POST /v1/jobs` | JSON `{"path","model"?,"language"?,"task"?,"force"?,"diarize"?}` | `202 {"id","status":"queued"}`; 403 if the path is outside the library roots or watched folders; 404 if missing |
| `GET /v1/jobs` | none | `{"data":[job...]}` |
| `GET /v1/jobs/:id` | none | `{"id","status","progress","source","output","model","error","created_at"}` |
| `DELETE /v1/jobs/:id` | none | 200 after cancelling |

Job status values: `queued`, `preparing_model`, `decoding`, `transcribing`, `done`, `failed`, `cancelled`, `skipped`. Synchronous routes wait behind other queued jobs. `model=whisper-1` is accepted and maps to the default model. `encode=false` means the upload is raw 16-bit little-endian PCM.

```bash
FIX=Packages/SynapseCore/Tests/SynapseCoreTests/Fixtures
curl -s localhost:9000/health
curl -s localhost:9000/v1/models
curl -s localhost:9000/v1/audio/transcriptions -F file=@$FIX/en.mkv -F response_format=srt
curl -s "localhost:9000/asr?task=transcribe&language=en&output=srt&encode=false" -F audio_file=@$FIX/en.pcm
curl -s -X POST "localhost:9000/detect-language?encode=false" -F audio_file=@$FIX/en.pcm
```

### Connecting a client

Give a client only the host (for example `http://192.168.1.20:9000`) and the API key. Every API route answers with and without the `/v1` prefix (and at `/v1/v1`, for a `host/v1` base URL pasted into a client that adds `/v1` itself), so OpenAI SDKs work with `base_url` set to the host or `host/v1`, and the Anthropic SDK works with the host. The key is accepted as `Authorization: Bearer <key>` (OpenAI clients), `x-api-key: <key>` (Anthropic clients), or a `/k/<key>` path prefix. Each protocol answers in its own shape, streaming (SSE) or not. `scripts/verify-connect.py <host> <key>` checks all of this with the official SDKs.

### Chat and vision (Qwen3.5)

| Route | Notes |
|---|---|
| `POST /v1/chat/completions` | `messages` with string content or parts (`text`, `image_url` with a `data:` or `http(s)` URL, `video_url` with an MP4/MOV `data:` or `http(s)` URL, `input_audio` with base64 `data` and a `format` for omni models); `modalities: ["text", "audio"]` with `audio: {"format", "voice"}` for a spoken reply in `message.audio` (`wav`, `mp3`, `flac`, `opus`, `aac`, `pcm16`; streaming needs `pcm16` and sends `delta.audio`); `max_tokens`/`max_completion_tokens`, `temperature`, `top_p`, `stop`, `stream`, `stream_options.include_usage`. |
| `POST /v1/completions` | OpenAI legacy completions: one `prompt` string continued as raw text (no chat template); `max_tokens` (default 256), `temperature`, `top_p`, `stop`, `echo`, `stream`, `stream_options.include_usage`. |
| `POST /v1/responses` | `input` as a string or message items with `input_text` / `input_image` / `input_video` / `input_audio` parts; `instructions`, `max_output_tokens`, `temperature`, `top_p`, `stream` (typed SSE events through `response.completed`). |
| `POST /v1/messages` | Anthropic Messages: `system`, `messages` with `text`, `image` (base64 or url), `tool_use` and `tool_result` blocks; `max_tokens`, `temperature`, `top_p`, `stop_sequences`, `tools`, `tool_choice`, `thinking`, `stream` (named SSE events `message_start` through `message_stop`). `claude-*` model ids map to the default chat model. |
| `POST /v1/messages/count_tokens` | same body as `/v1/messages` | `{"input_tokens": n}` |

`model` is a catalog id such as `qwen3.5-0.8b`; omit it to use the smallest downloaded chat model. Qwen3.5 thinking mode is off unless `reasoning_effort` (Chat Completions) or `reasoning.effort` (Responses) is set to something other than `none` or `minimal`, or `thinking.type` (Messages) is `enabled` or `adaptive`; Messages returns the reasoning as a `thinking` block. Messages `tool_choice` of `any` or a named tool is treated as `auto`. Images are capped at about one megapixel before they reach the model. One chat model stays loaded at a time.

OpenAI Python SDK:

```python
from openai import OpenAI

c = OpenAI(base_url="http://localhost:9000/v1", api_key="x")  # use the real key when LAN is on
print(c.audio.transcriptions.create(model="whisper-1", file=open("en.m4a", "rb"), response_format="srt"))

import base64
img = "data:image/jpeg;base64," + base64.b64encode(open("zebra.jpg", "rb").read()).decode()
r = c.responses.create(model="qwen3.5-0.8b", input=[{"role": "user", "content": [
    {"type": "input_text", "text": "What animal is this?"},
    {"type": "input_image", "image_url": img}]}])
print(r.output_text)
```

Anthropic Python SDK (the host is enough; the SDK adds `/v1`):

```python
import anthropic

c = anthropic.Anthropic(base_url="http://localhost:9000", api_key="x")
m = c.messages.create(model="qwen3.5-0.8b", max_tokens=256, messages=[{"role": "user", "content": "Hi"}])
print(m.content[0].text)
```

### Images

| Route | Notes |
|---|---|
| `POST /v1/images/generations` | OpenAI Images: `prompt`, `size`, `n`, `stream` (partial-image SSE). Models: `flux2-klein-4b`, `z-image-turbo`, `qwen-image-2.1-q4`. |
| `POST /v1/images/edits` | multipart `image` + `prompt` (FLUX.2 klein). |
| `POST /v1/responses` with `tools: [{"type": "image_generation"}]` | the chat model writes the prompt and the image model draws it. |

### Video in chat

Qwen3.5 models and the omni models (except Gemma 3n) read video. Send a `video_url` part (Chat Completions) or `input_video` part (Responses) holding an MP4 or MOV as a `data:` URL or an `http(s)` URL, up to 200 MB. Synapse samples 8 frames. File paths and `file://` URLs are refused. A model without video input returns 400.

### Speech, sound and embeddings

| Route | Notes |
|---|---|
| `POST /v1/audio/speech` | OpenAI speech: `input` (up to 4096 characters), `voice`, `response_format` (`mp3` default, `opus`, `aac`, `flac`, `wav`, `pcm`), `speed`, `stream_format` (`audio` or `sse`). `tts-1`, `tts-1-hd` and `gpt-4o-mini-tts` mean the first downloaded of PocketTTS and Kokoro. PocketTTS ignores `speed`; OpenAI voice names use the default voice. |
| `POST /v1/audio/generations` | Synapse's own: `prompt`, `seconds` (1 to 120, default 8), `seed`, `response_format` (`wav` default keeps stereo; other formats are mono). Models: `stable-audio-3-small-sfx`, `stable-audio-3-small-music`. |
| `POST /v1/embeddings` | OpenAI embeddings: `input` (text or a list of texts, up to 256), `encoding_format` (`float` or `base64`, the SDK default), `dimensions`. `text-embedding-3-small`, `-3-large` and `ada-002` mean the default model. Token-array input returns 400; in LangChain set `check_embedding_ctx_length=False`. |
| `POST /v1/rerank` | Cohere and Jina shape: `query`, `documents` (strings or `{"text"}`), `top_n`, `return_documents`. Model: `qwen3-reranker-0.6b`. |

```python
c.audio.speech.create(model="tts-1", voice="alloy", input="Hello from Synapse.").write_to_file("hello.mp3")
v = c.embeddings.create(model="text-embedding-3-small", input=["Paris is the capital of France."]).data[0].embedding
```

```bash
curl -s localhost:9000/v1/audio/generations -H 'Content-Type: application/json' \
  -d '{"prompt":"rain on a tin roof","seconds":5}' -o rain.wav
```

### Video generation

OpenAI Videos API: `POST /v1/videos` (`prompt`, `seconds` `4`/`8`/`12`, `size` from 256 to 1920 per side, `input_reference` start image, `seed`), `GET /v1/videos/{id}`, `GET /v1/videos`, `GET /v1/videos/{id}/content` (`variant=video` or `thumbnail`), `DELETE /v1/videos/{id}`. `sora-2` and `sora-2-pro` mean the downloaded video model. Clips render one at a time and are kept for a day. Each side is generated at the nearest smaller multiple of 64 (1280x720 renders at 1280x704). The model, LTX-2.3 Distilled, needs about 96 GB of memory and disk.

```python
v = c.videos.create(model="sora-2", prompt="A red fox walking through snow", seconds="4", size="1280x720")
while v.status in ("queued", "in_progress"):
    time.sleep(5); v = c.videos.retrieve(v.id)
c.videos.download_content(v.id).write_to_file("fox.mp4")
```

### Omni models

`gemma-3n-e2b` (audio and image), `gemma-4-e2b`, `lfm3-omni-2b`, `minicpm-o-4.5` and `qwen3-omni-30b` run in a managed mlx-vlm server and answer on every chat route. Send audio as an `input_audio` part; non-WAV audio is converted to 16 kHz WAV first. Small omni models follow the prompt closely: "Transcribe the audio." works better than "What does the speaker say?".

`lfm3-omni-2b` also speaks. Ask Chat Completions for audio with it, or pick it for a voice call (`/v1/realtime?model=lfm3-omni-2b` with audio output, or **Live → Voice call**) and it hears your turn and any camera frame itself, then answers in its own voice, streamed as it is generated; there is no separate speech synthesis. Barge-in stops it mid-sentence. On an M4 Mac mini the first audio arrives about 0.75 s after you stop talking once the model is loaded. Speech recognition still runs, only to show your words in the transcript.

### Any model from Hugging Face

**Models → +** takes a Hugging Face repo (`org/name`) or its link. Synapse reads the repo's files and `config.json` and tells you how it would run it before anything downloads: chat and vision models whose architecture the Swift MLX libraries know run in-process (text-only architectures such as Llama included); other architectures run through mlx-vlm; embedding models run in Embed. GGUF-only repos, diffusers pipelines and speech or image generators are refused with the reason. Added models appear under "Added from Hugging Face", download like catalog models, and are called by their repo id (`"model": "mlx-community/Llama-3.2-1B-Instruct-4bit"`).

### Python runtimes

Video generation (mlx-video), sound generation (mlx-audio) and omni models (mlx-vlm) run through Python tools that Synapse installs on first use under `<models folder>/runtimes/`. The first use needs a network connection and takes a few minutes. Video generation also needs `git` (Xcode Command Line Tools). Gated models (FLUX.2 klein 9B) need their license accepted on Hugging Face and a token: Synapse uses the `hf auth login` token (or `HF_TOKEN`) automatically, or one set in **Settings**. Stable Audio is under the Stability AI Community License but is not gated.

### Realtime and duplex speech

`GET /v1/realtime?model=<id>` (WebSocket, OpenAI Realtime events). Add `&intent=transcription` for live transcription only. `conversation.item.create` accepts `input_image` parts (base64 `data:image` URLs): a vision chat model sees the frame with the user's next turn, and the latest two frames are kept. The **Live** pane's Voice call sends a camera frame this way each time you start talking. The duplex models talk back in one model: `personaplex-7b` and `voicechat-11b` for voice calls, `hibiki-zero-3b` for live French-to-English speech translation. The app's **Live** pane uses the same sessions with the microphone.

### vOOM (models larger than memory)

Set **Settings → vOOM checkout** to a vOOM checkout with its `.venv`. Synapse then lists `voom:<model>` ids and starts the vOOM server on demand. vOOM pages weights from the SSD, so a model larger than free memory still runs, only slower. It serves chat (`/v1/chat/completions`, `/v1/responses`) for models in its own `models/` folder, and `/v1/images/generations` for Z-Image Turbo from Synapse's models folder (`voom:Z-Image-Turbo-bf16`). Set `VMODEL_IMAGE_WEIGHT_BUDGET_MB` in Synapse's environment to cap the image weights kept resident (default 6000).

## Bazarr setup

In Bazarr, add the Whisper provider and set its endpoint to:

- Bazarr on another machine: `http://<mac-ip>:9000/k/<api-key>` (enable Allow LAN in Synapse first; the Server tab shows this string).
- Bazarr on the same Mac: `http://127.0.0.1:9000`.

Bazarr uses the model set as the Bazarr model in Synapse settings, falling back to the default model. Language detection needs a multilingual Whisper model downloaded.

## Watched folders

Add folders in the Watch Folders tab. For each new media file, Synapse writes a sidecar `Movie.<lang>.srt` next to it. If that sidecar already exists, the file is skipped. New files are picked up through FSEvents once their size is stable. Because FSEvents can miss changes on network shares, folders are also rescanned every 10 minutes.

## Known limitations

- Whisper can hallucinate text over silence or music (for example "Thanks for watching"). VAD chunking reduces this but does not remove it.
- The first use of a model compiles it for Core ML, which can take several minutes for large models. The job shows "preparing model" during this time.
- Only the first audio track of a file is transcribed.
- Parakeet does not translate or detect language and covers 25 European languages. Synapse falls back to Whisper for other requests.
- Speaker labels come from a separate diarization model and can split one speaker in two, or merge similar voices, on short clips.
- Video input reads MP4 and MOV only (AVFoundation); MKV and WebM are refused.
- Of the omni models, only `lfm3-omni-2b` and `minicpm-o-4.5` speak themselves. Other chat models answer voice calls and Chat Completions audio requests through speech synthesis (PocketTTS or Kokoro), whose voices do not follow OpenAI's voice names.
- Video jobs do not survive a restart.

## Releases (maintainers)

Pushing a tag `v*` runs `.github/workflows/release.yml`, which builds, signs, and publishes a GitHub Release (tags containing `-` are prereleases). Without secrets the app is ad-hoc signed. For Developer ID signing and notarization (paid Apple Developer account), set these repository secrets:

- `DEVELOPER_ID_CERT_P12` (base64 of the exported .p12)
- `DEVELOPER_ID_CERT_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD` (app-specific password)

## License and notices

See `THIRD_PARTY_NOTICES.md`.
