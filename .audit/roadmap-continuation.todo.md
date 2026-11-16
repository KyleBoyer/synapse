# Roadmap continuation

- [x] Read the Principles section of the poteto-mode skill.
- [x] Phase A: Frame. Existing image API routes reach a placeholder. Done requires real output per family, strict SDK Responses checks, realtime audio and app checks, and vOOM proxy and paged image checks.
- [x] Phase B: Design the workflow. Preserve existing ImageRequest/ImageEngine boundary. Vendor and verify libraries, wire and verify image engines, then Responses tools, realtime and Live, and vOOM in roadmap order.
- [ ] Phase C: Run the loop.
- [ ] Vendor FLUX.2 and Z-Image with source revision, license, minimal MLX patch. Build.
- [ ] Connect FLUX.2, Z-Image, mflux. Generate PNGs and edit through API with real weights.
- [ ] Add Responses image_generation with Qwen prompt and official SDK checks.
- [ ] Add realtime WebSocket, Live pane, FluidAudio and duplex engines. Verify synthesized speech and interruption.
- [ ] Add optional vOOM chat sidecar; verify real model reply.
- [ ] Add vOOM Z-Image weight paging under its repository rules; verify actual image.
- [ ] Phase D: Keep the audit trail.
- [ ] Phase E: Verify and hand back.

## Throughput checkpoint

- Blocking first steps. Read current contracts and recover scratch prototypes. Download weights while working.
- Independent workstreams. Source investigation and isolated backend implementation can overlap. API integration follows backend build.
- Shared mutable state. Separate writing worktrees. Serialize dependency resolution and GPU model checks on this 16 GB machine.
- Smallest safe decomposition. Keep the existing ImageEngine protocol; no new plugin registry. Each backend owns its existing library or subprocess state.

## Scope and risks

Package manifests, vendored core sources and notices, ImageEngines implementations and resources, API tests and model smoke tests, Responses routes, realtime server/app files, roadmap. Preserve downloads, API contracts, cancellation and model leases. Never run large model inference concurrently.

No publication or PR requested; keep changes local. Later roadmap gates stay open until their real checks run.
