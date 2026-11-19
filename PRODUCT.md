# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native SwiftUI app for Apple silicon Macs. Requires macOS 26 (Liquid Glass), confirmed by the owner. Design in Apple's macOS Human Interface conventions; the iOS reference applies only where macOS shares it.

## Users

Primary: the owner and homelab power users. Technical people who run a Mac (a 16 GB laptop today, a 128 GB Mac Studio next) as a local AI box. They wire it to Bazarr, Plex libraries, OpenAI and Anthropic SDK clients and agents, and they are fluent in ports, API keys, model ids, quantization and memory budgets.

Their main job in the window: confirm a model works, and see how fast or slow and how good or bad it is, before serving it over the API. Use across panes is evenly mixed: transcription, chat and vision, image generation, live speech, model and memory management, server setup.

Later (not in this pass): a default-on basic mode so general Mac users can transcribe and chat without touching API concepts. The first pass designs for power users; nothing should block adding that mode.

## Product Purpose

One local app that downloads, runs, tests and serves local models: Whisper and Parakeet transcription with subtitle output, Qwen3.5 chat and vision, image generation (FLUX.2 klein, Z-Image Turbo, Qwen-Image), realtime speech (live captions, voice calls, translation, full-duplex speech models), all served over OpenAI-compatible and Anthropic Messages APIs plus Bazarr's ASR API. Success: the owner trusts what a model will do over the API because they watched it do the same thing in the app, with honest speed and memory numbers.

## Positioning

Everything runs on the Mac, in one native app that is also the server: the same engines the GUI drives are the ones API clients hit, so testing in the window is testing the deployment. Optional vOOM integration pages weights from the SSD so models larger than memory still run.

## Operating Context

- Lives in the menu bar; the window opens to test, inspect, or configure, then closes while the server keeps running.
- Typical loop: download a model, try it in its pane, read its speed and memory, then point a client at `http://<mac>:9000`.
- Media libraries on NAS shares (watched folders), Bazarr on another machine (LAN mode with an API key), SDK scripts and agents.
- Long operations: model downloads of many GB, first-run model compilation (minutes), image generation (seconds to minutes), memory pressure and swapping on the 16 GB Mac.

## Capabilities and Constraints

- Panes today: Transcribe, Chat, Images, Video, Audio (Sound & Music, Speech, Clean Up), Embed, Live, Models, Memory, Watch Folders, Server, plus Settings and a menu bar extra.
- Modalities: transcription with speaker labels, chat with image, video and (omni models) audio input, image generation, video generation, text to speech, sound and music generation, embeddings and reranking, realtime speech with camera frames, voice calls with an omni model that hears and speaks itself (LFM3 Omni), full-duplex speech.
- Some engines are Python tools (mlx-video, mlx-audio, mlx-vlm) installed on first use under the models folder; their models run as separate processes, one per clip or one server per omni model.
- The dev Mac has 16 GB. LTX-2.3 video (about 96 GB), MiniCPM-o and Qwen3-Omni are verified only with mocks or not at all until they run on a 128 GB Mac Studio.
- Measured per run, from model-ready: time to first token, decode and prompt rates, transcription speed, denoising step and image time, first audio, speech speed, embedding rate, video time and sound generation speed (the last two include model load, since each clip runs in a fresh process). Also shown: download and job progress, image previews, resident model bytes, the memory budget and over-budget state.
- One loaded engine per kind; a memory budget unloads idle models; a process-wide GPU gate serializes inference. Resident sizes are measured once loaded (weights, peak image memory, or helper-process footprint), estimated before.
- Running models: a prompt cache on every chat engine (in memory, and on disk for long prompts), KV precision (full, 8-bit, 4-bit), speculative decoding with a draft model (full-attention models only), full sampling controls, a thinking budget, and keep-loaded models. Each chat model card counts its cache hits from every request, the API included.
- Work done in the panes is saved as history (never API requests) and can be deleted per item, per pane, or all at once.
- Model ids are user-facing (they are what API clients send), so they stay visible next to display names.

## Brand Commitments

- Name: Synapse. App icon: a small neural network of nodes on a violet rounded square, drawn by scripts/make-icon.swift (Synapse/Assets.xcassets).
- Owner pinned: modern macOS 26 Liquid Glass; replace the stock white/grey Form look, default buttons, dropdowns and checkboxes with something distinctive and polished.

## Evidence on Hand

- Real models downloaded on the dev Mac: qwen3.5-0.8b, whisper-tiny, parakeet-v3, flux2-klein-4b, z-image-turbo, qwen-image-2.1-q4, realtime speech models, three duplex models, qwen3-embedding-0.6b, qwen3-reranker-0.6b, speaker-diarizer, gemma-3n-e2b, gemma-4-e2b, lfm3-omni-2b, stable-audio-3-small-sfx.
- Measured numbers exist only from test runs (for example Z-Image paged through vOOM: 70 s at 512x512, 4.27 GB peak). No benchmarks, users, or testimonials to cite; never invent them.

## Product Principles

1. Show the truth about a model: speed, memory, and quality are visible where the model runs, never hidden in logs.
2. The app and the API are one thing; every pane should make the matching API call obvious.
3. Long work is never silent: downloads, first-run preparation, generation and paging always show state and progress.
4. Power first, approachable later: dense and precise for experts now, structured so a basic mode can sit on top.

## Accessibility & Inclusion

Standard macOS expectations: VoiceOver labels on icon-only controls, keyboard operation, Dynamic Type where macOS supports it, Increase Contrast and Reduce Transparency honored (important with glass), Reduce Motion honored.
