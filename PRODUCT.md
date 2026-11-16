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

- Panes today: Transcribe, Chat, Images, Live, Models, Memory, Watch Folders, Server, plus Settings and a menu bar extra.
- Metrics the engines already expose or can expose: download progress, job progress, image step progress and previews, realtime first-audio latency, resident model bytes, memory budget, over-budget state. Tokens per second and similar speed figures are wanted but not all computed yet.
- One loaded engine per kind; a memory budget unloads idle models; a process-wide GPU gate serializes inference.
- Model ids are user-facing (they are what API clients send), so they stay visible next to display names.

## Brand Commitments

- Name: Synapse. App icon: white waveform bars on an indigo-to-violet-to-magenta rounded square (Synapse/Assets.xcassets).
- Owner pinned: modern macOS 26 Liquid Glass; replace the stock white/grey Form look, default buttons, dropdowns and checkboxes with something distinctive and polished.

## Evidence on Hand

- Real models downloaded on the dev Mac: qwen3.5-0.8b, whisper-tiny, parakeet-v3, flux2-klein-4b, z-image-turbo, qwen-image-2.1-q4, realtime speech models, three duplex models.
- Measured numbers exist only from test runs (for example Z-Image paged through vOOM: 70 s at 512x512, 4.27 GB peak). No benchmarks, users, or testimonials to cite; never invent them.

## Product Principles

1. Show the truth about a model: speed, memory, and quality are visible where the model runs, never hidden in logs.
2. The app and the API are one thing; every pane should make the matching API call obvious.
3. Long work is never silent: downloads, first-run preparation, generation and paging always show state and progress.
4. Power first, approachable later: dense and precise for experts now, structured so a basic mode can sit on top.

## Accessibility & Inclusion

Standard macOS expectations: VoiceOver labels on icon-only controls, keyboard operation, Dynamic Type where macOS supports it, Increase Contrast and Reduce Transparency honored (important with glass), Reduce Motion honored.
