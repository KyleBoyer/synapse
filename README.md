# Synapse

Synapse is a native macOS app that transcribes audio and video into subtitles using local models. Nothing leaves your Mac. It runs Whisper (via WhisperKit) and NVIDIA Parakeet (via FluidAudio) on Core ML, and exposes an HTTP API that is compatible with the OpenAI transcription API and with Bazarr's Whisper provider. It can also watch folders and write subtitle files next to your media. It also runs Qwen3.5 chat and vision models (0.8B, 2B, 4B, 9B) on MLX, served through OpenAI-compatible Chat Completions and Responses endpoints.

## Requirements

- Apple Silicon Mac
- macOS 15 or later

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

With the app running and `qwen3.5-0.8b` downloaded, `scripts/verify-openai-api.py` checks the chat endpoints with the official OpenAI Python SDK (`pip install openai`). It validates every response and stream event against the SDK's types.

## HTTP API

Default address is `http://127.0.0.1:9000`. The port and LAN access are set in the Server tab. With LAN off, no key is needed. With LAN on, every route except `/health` needs the API key, sent as `Authorization: Bearer <key>` or as a path prefix `/k/<key>/...`. Errors use `{"error":{"message":"...","type":"invalid_request_error"}}`.

| Method and path | Input | Output |
|---|---|---|
| `GET /health` | none | `{"status":"ok","version":"0.1.0"}` |
| `GET /v1/models` | none | OpenAI-style list of downloaded models |
| `POST /v1/audio/transcriptions` | multipart: `file`, `model`, `language`, `response_format` (default `json`); `prompt`, `temperature`, `timestamp_granularities[]` are ignored | transcript in the requested format |
| `POST /v1/audio/translations` | same, translates to English | same |
| `POST /asr` | query: `task`, `language`, `output` (txt, vtt, srt, tsv, json; default `txt`), `encode` (default `true`); multipart: `audio_file`. `word_timestamps`, `vad_filter`, `initial_prompt`, `video_file` are ignored | rendered format as `text/plain` with `Content-Disposition` and `Asr-Engine: synapse` |
| `POST /detect-language` | query: `encode`; multipart: `audio_file` | `{"detected_language":"english","language_code":"en","confidence":0.97}`; `und` if no multilingual Whisper model is downloaded |
| `POST /v1/jobs` | JSON `{"path","model"?,"language"?,"task"?,"force"?}` | `202 {"id","status":"queued"}`; 403 if the path is outside the library roots or watched folders; 404 if missing |
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

### Chat and vision (Qwen3.5)

| Route | Notes |
|---|---|
| `POST /v1/chat/completions` | `messages` with string content or parts (`text`, `image_url` with a `data:` or `http(s)` URL); `max_tokens`/`max_completion_tokens`, `temperature`, `top_p`, `stream`, `stream_options.include_usage`. |
| `POST /v1/responses` | `input` as a string or message items with `input_text` / `input_image` parts; `instructions`, `max_output_tokens`, `temperature`, `top_p`, `stream` (typed SSE events through `response.completed`). |

`model` is a catalog id such as `qwen3.5-0.8b`; omit it to use the smallest downloaded chat model. Qwen3.5 thinking mode is off unless `reasoning_effort` (Chat Completions) or `reasoning.effort` (Responses) is set to something other than `none` or `minimal`. Images are capped at about one megapixel before they reach the model. One chat model stays loaded at a time.

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

## Releases (maintainers)

Pushing a tag `v*` runs `.github/workflows/release.yml`, which builds, signs, and publishes a GitHub Release (tags containing `-` are prereleases). Without secrets the app is ad-hoc signed. For Developer ID signing and notarization (paid Apple Developer account), set these repository secrets:

- `DEVELOPER_ID_CERT_P12` (base64 of the exported .p12)
- `DEVELOPER_ID_CERT_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD` (app-specific password)

## License and notices

See `THIRD_PARTY_NOTICES.md`.
