---
version: 1
slug: "synapse-synapseapp-swift"
primary_target: "Synapse/SynapseApp.swift"
related_targets: ["Synapse/Views"]
---

# Synapse main window (all panes)

Scope: the whole app window (sidebar, every pane, settings, menu bar extra). Mode: Operate.
Audience and job: homelab power users confirming a model works and how fast, slow, good or bad it is before serving it over the API. Use is evenly mixed across panes.
Constraints: macOS 26 only; native controls and navigation; restrained color (no game feel); prominent live metrics on every working pane; model ids always visible.
Owner steer: fuse Burn-in (live layer) with Datasheet (measured record), with more macOS Liquid Glass transparency.

## Direction contract

THESIS: A model is a component under test. Every working pane runs it live with the clock burned in; the Models pane keeps its datasheet. Refuses the stock opaque grouped-Form app with metrics hidden in logs.

OWN-WORLD: Translucent window (desktop shows through) with Liquid Glass sidebar, toolbar and floating panels; system appearance, light and dark. Ink is primary/secondary label; the app accent is the icon's violet (selection, prominent buttons, on-switches; owner: "Keep violet"); one reserved live color, subtitle yellow (amber in light), used only for what is happening now: streaming text, the active job, the open mic, the current metric. SF Pro for content at subtitle weight; SF Mono tabular for every number, timecode and model id. Red, orange, green only for failure, warning, ready.

STORY: Pick a model, run it, watch the burn-in readout (first token, rate, memory) move, then read the datasheet's Min/Typ/Max built from your runs, then copy the matching API call.

FIRST VIEWPORT: Glass sidebar (Try: Transcribe, Chat, Images, Live; Run: Models, Memory, Watch Folders, Server) with a live dot on the active pane and a server/memory footer. Toolbar: pane title, model capsule with mono id. Content: output stream with a mono timecode gutter, subtitle-weight text. Top right: floating glass burn-in panel with mono metric rows and a run-history sparkline (live bar in yellow). Bottom: floating glass composer or run control.

FORM: Burn-in (assigned, candidate 6 of 7) fused at the owner's request with Datasheet (my top-ranked pick). seed:a6f5adee5ddeac70

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
