---
name: Synapse
description: A local model bench for the Mac: run a model live, watch the burn-in readout, read its datasheet, copy the API call.
colors:
  signal-violet: "#5B3FD6"
  signal-violet-dark: "#7A5AF8"
  burn-in-yellow: "#F5D90A"
  burn-in-amber: "#8C6B00"
typography:
  display:
    fontFamily: "SF Pro (system .largeTitle)"
    fontSize: "26pt"
    fontWeight: 700
  subtitle:
    fontFamily: "SF Pro (system .title3)"
    fontSize: "15pt"
    fontWeight: 500
  headline:
    fontFamily: "SF Pro (system .headline)"
    fontSize: "13pt"
    fontWeight: 700
  body:
    fontFamily: "SF Pro (system .body / .callout)"
    fontSize: "13pt"
    fontWeight: 400
  label:
    fontFamily: "SF Pro (system .caption)"
    fontSize: "10pt"
    fontWeight: 600
  mono:
    fontFamily: "SF Mono (system design .monospaced, monospacedDigit)"
    fontSize: "10pt"
    fontWeight: 400
    fontFeature: "tnum"
  mono-reading:
    fontFamily: "SF Mono (system design .monospaced, .callout)"
    fontSize: "12pt"
    fontWeight: 500
    fontFeature: "tnum"
rounded:
  thumb: "8pt"
  media: "12pt"
  tile: "14pt"
  panel: "18pt"
  bar: "22pt"
spacing:
  tight: "8pt"
  row: "10pt"
  stack: "12pt"
  panel-inset: "14pt"
  pane-inset: "16pt"
components:
  burn-in-panel:
    rounded: "{rounded.panel}"
    padding: "14pt"
    width: "288pt"
  readout-column:
    padding: "{spacing.pane-inset}"
    width: "320pt"
  glass-bar:
    rounded: "{rounded.bar}"
    padding: "8pt 12pt"
  button-prominent:
    backgroundColor: "{colors.signal-violet}"
    textColor: "#FFFFFF"
  sidebar-footer:
    rounded: "{rounded.tile}"
    padding: "{spacing.row}"
  timecode-gutter:
    typography: "{typography.mono}"
    width: "82pt"
---

# Design System: Synapse

## Overview

**Creative North Star: "The Bench Under Glass"**

Synapse treats a model as a component under test. Every working pane runs it live with the clock burned in: a mono timecode gutter beside the output, a floating glass readout of what the model is doing right now, and a run history whose newest bar burns yellow. The Models pane keeps the measured record, a datasheet with Min / Typ / Max built from runs on this Mac. The look is a native macOS 26 window made of Liquid Glass, where the desktop shows through the chrome and the work area stays calm enough to read.

Density is that of a pro tool: system text styles at their native sizes, every number in tabular SF Mono, model ids always beside display names. Color is nearly absent. Ink is the system's primary and secondary label; the accent is the app icon's violet, carried only by native controls; one reserved color marks what is happening now. Confirmed rejections from the owner: a non-native look, and too many colors or a game feel.

**Key Characteristics:**
- Native SwiftUI controls and navigation throughout; no custom-drawn buttons, switches or popups.
- Three layers of glass: a clear window, a see-through sidebar, a lightly frosted work area.
- One accent (icon violet), one live color (subtitle yellow / amber), status hues only for status.
- SF Pro for words, SF Mono tabular for every number, timecode and model id.
- Floating glass panels and full-width glass bars; no drop shadows.

## Colors

A colorless glass instrument with one brand voice and one signal light.

### Primary
- **Signal Violet** (`AccentColor`, light `signal-violet`, dark `signal-violet-dark`): the app icon's violet, set as the asset-catalog AccentColor so the system applies it. It appears only where macOS puts the accent: sidebar and list selection, `.glassProminent` buttons (Send, Download, Try in Chat, Done), on-switches. Owner decision: "Keep violet" (it replaces macOS blue).

### Secondary
- **Burn-in Yellow / Burn-in Amber** (`Color.live`; dark `burn-in-yellow`, light `burn-in-amber`): subtitle yellow in dark, a deeper amber in light so it holds contrast on pale glass. Used for the streaming line's timecode, interim live captions, "Waiting for first token…", the active pane's dot, the newest run-history bar, live readout values, download and job progress tints, the memory bar while a model is leased, "loaded" sizes, and the drop-target outline.

### Neutral
- **Primary Ink** (system `labelColor`): content, model output, readout values at rest.
- **Secondary Ink** (system `secondaryLabelColor`): labels, model ids, timecodes of settled lines, user messages, footnotes, remembered (typical) values.
- **Window Fill** (system `windowBackgroundColor`): the tint every glass layer carries: 8% on the window glass, 45% on the sidebar glass, 35% on the work area's frosted glass (user-adjustable, see Depth).
- **History Grey** (`Color.secondary` at 45%): past bars in the run history.

### Status (system colors, not brand)
- **Green** (`.green`): ready (downloaded checkmark, server running dot, "Recommended for this Mac").
- **Orange** (`.orange`): warning (failed download, over memory budget, startup error, "More than this Mac's memory").
- **Red** (`.red`): failure (server failed dot, error text).

### Named Rules
**The Now Rule.** Burn-in yellow is reserved for what is happening now: streaming text, the active job, the open mic, the current metric. If it would still be true after the run ends, it is not live. (Owner decision.)

**The One Accent Rule.** Violet reaches the screen only through native control states. Never paint text, icons, backgrounds or charts with it. (Owner decision: "Keep violet".)

**The Status-Only Rule.** Red, orange and green mean failure, warning and ready, nothing else. No other hues enter the system. (Owner decision: avoid too many colors / game feel.)

## Typography

**Display Font:** SF Pro (system text styles)
**Body Font:** SF Pro (system text styles)
**Label/Mono Font:** SF Mono via `Font.mono(style, weight)`: `.monospaced` design with `.monospacedDigit()`

**Character:** Apple's own faces at Apple's own sizes. The voice comes from weight (model output at subtitle weight) and from the mono layer that turns every figure into an instrument reading.

### Hierarchy
- **Display** (`.largeTitle` bold): the model name at the top of a datasheet, with its id beneath in mono `.title3` secondary.
- **Subtitle** (`Font.subtitle`: `.title3` medium): model output in Chat and transcripts, idle prompts ("Listening…"). The user's own message is `.title3` regular in secondary ink, so the model's words lead.
- **Headline** (`.headline`): panel and section titles, model names in the burn-in panel and `ModelTitle`.
- **Body / Callout** (`.body`, `.callout`): readout labels, datasheet parameters, metadata lines.
- **Label** (`.caption` semibold, secondary): the speaker line above a message ("You", model name), datasheet column headers. Sentence case, never tracked or uppercased.
- **Mono** (`Font.mono(.caption)`): timecodes, model ids, server address, API calls. **Mono reading** (`Font.mono(.callout, weight: .medium)`): burn-in values, with `.contentTransition(.numericText())` so changes roll instead of jumping. Datasheet Typ is mono body bold; Min / Max mono regular.

### Named Rules
**The Mono Number Rule.** Every number, timecode (`00:00:21.52`), size and model id is set in `Font.mono`, tabular, so columns and changing values never jitter.

**The Name-Then-Id Rule.** A model is shown the way API clients name it: display name, then the id in mono secondary, side by side on one baseline.

## Layout

A native `NavigationSplitView`: sidebar (190 to 210pt, sections **Try**: Transcribe, Chat, Images, Live; **Run**: Models, Memory, Watch Folders, Server) and a detail pane; window minimum 960 x 600. The toolbar carries the pane title and the pane's choices.

Working panes (Transcribe, Chat, Images, Live) share one grammar: the output stream on the left, a 320pt readout column on the right holding the 288pt burn-in panel (plus any settings panel, 12pt apart, 16pt inset), and a glass bar inset 16pt along the bottom. The bar sits in the bottom safe area, so the readout column sits above it and never overlaps. Output lines are rows of an 82pt mono timecode gutter, 16pt gap, then text; lines stack 14 to 16pt apart. Text columns cap at 760pt. Models is a 300pt list beside a datasheet padded 28pt.

Rhythm is an 8 / 10 / 12 / 14 / 16pt scale; 12 is the default stack gap, 16 the pane inset, 14 the panel inset.

### Named Rules
**The Full-Width Bar Rule.** Composer and run bars span the full pane width. (Owner decision.)

**The Fit-the-Value Rule.** Toolbar choices size to their current value (`ChoiceMenu`), never to their longest option; no short text stranded at the left of a wide capsule. (Owner decision.)

## Elevation & Depth

Depth is glass, not shadow. The code contains no `shadow()`. Layers, back to front:

1. **Window glass:** AppKit `NSGlassEffectView` on a non-opaque window, the Dock's material. Clear style with a fixed 8% window-color tint.
2. **Sidebar:** the split view's own sidebar glass, restyled to `.clear` with a window-color tint (default 45%, i.e. 55% transparency), so the desktop shows through clearly but not fully.
3. **Work area:** `WorkAreaGlass`, a `.regular` (frosted) `NSGlassEffectView` with a window-color tint (default 35%, i.e. 65% transparency). It starts at the sidebar's trailing edge (it keeps its leading safe area, because the detail column extends under the floating sidebar). Frosted, so the desktop shows through as soft tone and never as readable text.
4. **Floating glass:** `.glassEffect(.regular)` on the burn-in panel, settings panels, glass bars, the sidebar footer and the startup banner.

Settings > Appearance offers **Sidebar transparency** and **Content transparency** sliders (stored as tints in `glass.sidebarTint` / `glass.contentTint`, defaults in `WindowLook`, with Restore Defaults) and **System / Light / Dark** appearance (`AppAppearance`, applied to `NSApp.appearance`; also settable with the `-appearance Dark` launch argument).

### Named Rules
**The Three Glass Rule.** Window clear, sidebar see-through, work area only slightly translucent. (Owner decisions: "The sidebar being more transparent seems correct", then fully clear was "almost too much, maybe half that"; the middle wants a "slight" transparency; "I like this amount of opacity" for 55% sidebar / 65% content transparency, which are the defaults.) Never make the reading surface clear and never make the sidebar opaque.

**The No-Shadow Rule.** Floating surfaces separate by glass alone. Do not add drop shadows.

## Shapes

Continuous rounded rectangles in the system's language. The radius grows with a surface's size and role: 8pt thumbnails, 10 to 12pt images in the stream and results, 14pt tiles (sidebar footer, image canvas), 18pt floating panels (burn-in, settings panels, the drop-target outline), 22pt glass bars. Run-history bars are 10pt wide with a 1.5pt radius. Status and live dots are 7pt circles. Borders appear only as native `Divider`s, plus the 2pt live outline on a drop target.

## Components

### Buttons
- **Prominent:** `.buttonStyle(.glassProminent)`, tinted Signal Violet by the system. One per context: Send, Download, Try in Chat, Start, Done. `.controlSize(.large)` on datasheet actions and the Live start button.
- **Secondary:** `.buttonStyle(.glass)`: Stop, Delete…, Unload, export actions.
- **Inline / icon:** `.buttonStyle(.borderless)` with `.labelStyle(.iconOnly)`, an SF Symbol and a `.help` tooltip (Copy API call, Attach Image, Reset Measurements).

### Cards / Containers
- **Burn-in panel:** the signature. 288pt wide, 14pt padding, regular glass at 18pt. Header: headline name over mono caption id, live dot at the right while running. Rows: secondary label left, mono-reading value right (yellow when live, secondary when remembered). Then the run history (last 16 runs on a shared zero-based scale, newest bar yellow), a divider, and the API call in mono caption with a Copy button.
- **Settings panel:** same glass and size as the burn-in panel, built from `PanelRow`s.

### Inputs / Fields
- **Composer:** a plain multiline `TextField` (`.title3`, 1 to 6 lines) inside a glass bar, flanked by a borderless attach button and the prominent Send (or glass Stop).
- **Panel controls:** native switches (`.toggleStyle(.switch)`), steppers, rounded-border text fields with trailing mono text.

### Navigation
- **Sidebar:** native `List` with a hidden scroll background over the clear sidebar glass; SF Symbol icons in secondary ink; a 7pt live dot at the trailing edge of any pane with work in progress. Footer: glass tile with the server dot and address in mono, and a memory bar (yellow while leased, orange over budget).
- **Toolbar:** `ChoiceMenu` capsules sized to their value, showing display name plus mono id.

### PanelRow
Label on the left, control flush right (`Spacer(minLength: 12)`), so every control in a panel lines up. (Owner decision.)

### Datasheet
Large-title name, mono id, metadata line, then **Characteristics on this Mac**: a grid of Parameter (with its test conditions in caption) / Min / **Typ** / Max / Unit / Runs, separated by dividers, Typ in bold mono, and a footnote naming how Typ is computed. Ends with the API routes in mono and `model: <id>`.

## Do's and Don'ts

### Do:
- **Do** use native SwiftUI controls, button styles (`.glass`, `.glassProminent`, `.borderless`) and SF Symbols.
- **Do** put a burn-in panel (288pt, 18pt glass) on every working pane, with the matching API call and a Copy button.
- **Do** set every number, timecode and model id in `Font.mono`, and show a model id beside its display name.
- **Do** use `Color.live` only for what is happening now, and clear it when the run ends.
- **Do** make composer and run bars span the full pane width (`glassBar`, 22pt).
- **Do** size toolbar choices to their value with `ChoiceMenu`, and lay out panel settings with `PanelRow`.
- **Do** keep the work area under its blur and fill so the reading surface stays calm over any desktop.

### Don't:
- **Don't** build a non-native look: no custom-drawn controls, no hand-rolled popups or switches. (Owner.)
- **Don't** add colors: no second accent, no UI gradients (the icon's indigo-to-magenta gradient stays in the icon), no color-coding beyond violet, live and the status trio. (Owner: too many colors / game feel.)
- **Don't** use violet for text, icons or fills; it reaches the screen only through native control states.
- **Don't** use red, orange or green for anything but failure, warning and ready.
- **Don't** add drop shadows; depth comes from glass.
- **Don't** make the sidebar opaque or the work area fully clear.
- **Don't** let a native popup size to its longest option and strand a short value in a wide capsule.
