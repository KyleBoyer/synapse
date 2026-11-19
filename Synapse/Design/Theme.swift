import AppKit
import SwiftUI
import SynapseCore

extension Color {
    /// The one reserved color: only for what is happening now (streaming text, the active job, the open mic).
    /// Subtitle yellow in dark, a deeper amber in light so it keeps contrast on pale glass.
    static let live = Color(nsColor: NSColor(name: "live") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.85, blue: 0.04, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.42, blue: 0.0, alpha: 1)
    })
}

extension Font {
    /// Numbers, timecode and model ids: tabular so columns and changing values never jitter.
    static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight).monospacedDigit()
    }
    /// Model output, set at subtitle weight.
    static let subtitle = Font.system(.title3, weight: .medium)
}

/// `00:00:21.52`
func timecode(_ t: Double) -> String {
    let cs = Int((max(0, t) * 100).rounded())
    return String(format: "%02d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
}

func gigabytes(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

/// "48 MB" below a gigabyte, "1.4 GB" above (cache sizes span both).
func byteSize(_ bytes: Int) -> String {
    bytes < 1 << 30 ? String(format: "%.0f MB", Double(bytes) / 1_048_576) : gigabytes(bytes)
}

extension ResidentInfo {
    /// "≈" until the model's real memory has been measured (the estimate comes from the catalog).
    var memory: String { (measured ? "" : "≈") + gigabytes(bytes) }
}

/// A model shown the way API clients name it: display name, then the id they send.
struct ModelTitle: View {
    let name: String
    let id: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.headline)
            Text(id).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct LiveDot: View {
    var body: some View {
        Circle().fill(Color.live).frame(width: 7, height: 7).accessibilityLabel("Running")
    }
}

/// One line of the burn-in readout.
struct Reading: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var live = false
    /// A remembered value (typical from past runs) rather than this run's: shown in secondary ink.
    var muted = false
}

/// The floating glass readout every working pane carries: what the model is doing right now, its recent
/// history for the headline metric, and the API call that does the same thing.
struct BurnIn: View {
    let name: String
    let modelID: String
    let readings: [Reading]
    var history: [Double] = []
    var historyMetric: Metric?
    var running = false
    var api: String?
    /// What Copy puts on the pasteboard when the display form is not itself a usable call (e.g. a URL split for reading).
    var apiCopy: String?
    /// Several protocols for one model (chat): shown as one row that opens every format, instead of `api`.
    var apiFormats: [APIFormat] = []
    @State private var showingFormats = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.headline)
                    Text(modelID).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if running { LiveDot() }
            }
            VStack(spacing: 5) {
                ForEach(readings) { r in
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.label).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(r.value).font(.mono(.callout, weight: .medium))
                            .foregroundStyle(r.live ? Color.live : r.muted ? Color.secondary : Color.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .contentTransition(.numericText())
                    }
                }
            }
            .font(.callout)
            if let historyMetric, !history.isEmpty { RunHistory(values: history, metric: historyMetric) }
            if !apiFormats.isEmpty {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(apiFormats.map(\.shortName).joined(separator: " · ")).lineLimit(1)
                        Text("model: \(modelID)").lineLimit(1).truncationMode(.middle)
                    }
                    .font(.mono(.caption)).foregroundStyle(.secondary)
                    Spacer()
                    Button("API formats", systemImage: "chevron.left.forwardslash.chevron.right") { showingFormats = true }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Show the API formats for this model")
                        .popover(isPresented: $showingFormats, arrowEdge: .leading) { APIFormatsPopover(formats: apiFormats, modelID: modelID) }
                        #if DEBUG
                        // `-showAPIFormats YES` opens the popover after launch, for captures.
                        .task { if UserDefaults.standard.bool(forKey: "showAPIFormats") { try? await Task.sleep(for: .seconds(1)); showingFormats = true } }
                        #endif
                }
            } else if let api {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(api.split(separator: "\n").map(String.init), id: \.self) {
                            Text($0).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Copy API call", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(apiCopy ?? api, forType: .string)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy API call")
                }
            }
        }
        .padding(14)
        .frame(width: 288)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// One way to call a model over HTTP: the protocol's name, its route, and a ready-to-run curl command.
struct APIFormat: Identifiable, Hashable {
    let name: String
    let shortName: String
    let route: String
    let example: String
    var id: String { route }

    /// The chat protocols, newest first: OpenAI Responses, Anthropic Messages, then OpenAI Chat Completions.
    static func chat(model: String, base: String, key: String?) -> [APIFormat] {
        let bearer = key.map { " -H 'Authorization: Bearer \($0)'" } ?? ""
        let apiKey = key.map { " -H 'x-api-key: \($0)'" } ?? ""
        let json = " -H 'content-type: application/json'"
        return [
            APIFormat(name: "OpenAI Responses", shortName: "Responses", route: "POST /v1/responses",
                      example: "curl\(bearer) \(base)/v1/responses\(json) -d '{\"model\":\"\(model)\",\"input\":\"Hello\"}'"),
            APIFormat(name: "Anthropic Messages", shortName: "Messages", route: "POST /v1/messages",
                      example: "curl\(apiKey) \(base)/v1/messages\(json) -H 'anthropic-version: 2023-06-01' -d '{\"model\":\"\(model)\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"),
            APIFormat(name: "OpenAI Chat Completions", shortName: "Chat Completions", route: "POST /v1/chat/completions",
                      example: "curl\(bearer) \(base)/v1/chat/completions\(json) -d '{\"model\":\"\(model)\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"),
        ]
    }
}

/// Every format a model answers in, each with a copyable curl command.
struct APIFormatsPopover: View {
    let formats: [APIFormat]
    let modelID: String
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Call this model").font(.headline)
                Text("Any of these; clients only need the host and key.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(formats) { f in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.callout.weight(.semibold))
                        Text(f.route).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 16)
                    Button(copied == f.id ? "Copied" : "Copy curl", systemImage: copied == f.id ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.example, forType: .string)
                        copied = f.id
                    }
                    .buttonStyle(.glass).controlSize(.small)
                }
            }
            Text("model: \(modelID)").font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 360)
    }
}

/// The last runs of one metric on a shared zero-based scale; the newest bar is the live color.
struct RunHistory: View {
    let values: [Double]
    let metric: Metric
    var body: some View {
        let shown = Array(values.suffix(16))
        let top = max(shown.max() ?? 1, 0.0001)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(shown.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == shown.count - 1 ? Color.live : Color.secondary.opacity(0.45))
                        .frame(width: 10, height: max(2, 30 * shown[i] / top))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 30, alignment: .bottomLeading)
            Text("\(metric.label), last \(shown.count) runs").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label) over the last \(shown.count) runs, latest \(metric.format(shown.last ?? 0)) \(metric.unit)")
    }
}

extension View {
    /// A floating glass control surface (composer, run bar).
    func glassBar(cornerRadius: CGFloat = 22) -> some View {
        padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Window look, per user (UserDefaults keys used by @AppStorage). Tints are how much window-background color the glass
/// carries: 0 shows the desktop fully, 1 hides it. Defaults are the owner's chosen look.
enum WindowLook {
    static let sidebarTintKey = "glass.sidebarTint", contentTintKey = "glass.contentTint", appearanceKey = "appearance"
    /// Owner: fully clear was "almost too much", about half that.
    static let defaultSidebarTint = 0.45
    /// Owner: the middle wants a slight transparency. Frosted glass, so what shows through is tone, not readable text.
    static let defaultContentTint = 0.35
    /// The window glass itself stays nearly clear; the sidebar and work area add their own tint on top.
    static let windowTint = 0.08
    /// A tint at or above this is 0% transparency (the slider's last step).
    static let solid = 0.995
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    static var stored: AppAppearance {
        UserDefaults.standard.string(forKey: WindowLook.appearanceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}

/// Liquid Glass behind the whole window, the same material as the Dock. SwiftUI's glassEffect only refracts
/// what this app draws, so the window background uses AppKit's NSGlassEffectView on a non-opaque window.
struct WindowGlass: NSViewRepresentable {
    var sidebarTint: Double
    /// Both sliders at 0% transparency. In Dark appearance the glass stays see-through even fully tinted, so the
    /// window itself turns opaque and the glass sits on solid window color.
    var solidWindow = false

    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = WindowGlassView()
        v.cornerRadius = 0
        v.style = .clear
        v.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(WindowLook.windowTint)
        return v
    }

    func updateNSView(_ v: NSGlassEffectView, context: Context) {
        (v as? WindowGlassView)?.sidebarTint = sidebarTint
        (v as? WindowGlassView)?.solidWindow = solidWindow
    }

    final class WindowGlassView: NSGlassEffectView {
        var sidebarTint = WindowLook.defaultSidebarTint { didSet { needsLayout = true } }
        var solidWindow = false { didSet { applyWindow() } }

        private func applyWindow() {
            window?.isOpaque = solidWindow
            window?.backgroundColor = solidWindow ? .windowBackgroundColor : .clear
        }

        // The split view rebuilds its sidebar background on resize and collapse, so restyle on every layout pass.
        override func layout() {
            super.layout()
            matchSidebar()
        }

        /// The split view backs its sidebar with its own frosted glass; restyle it clear with the user's tint.
        /// shortcut: reaches into the split view's AppKit views because SwiftUI offers no sidebar background control on
        /// macOS; replace if a public API appears.
        func matchSidebar() {
            guard let root = window?.contentView else { return }
            func walk(_ v: NSView) {
                if let g = v as? NSGlassEffectView, g !== self, !(g is WorkAreaGlass.View), g.frame.height >= root.frame.height - 1 {
                    g.style = .clear
                    g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(sidebarTint)
                }
                v.subviews.forEach(walk)
            }
            walk(root)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindow()
        }
    }
}

/// A settings row inside a glass panel: label on the left, control flush right, so every control lines up.
struct PanelRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) { self.label = label; self.control = control() }
    var body: some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            control
        }
    }
}

/// A toolbar choice that sizes to the current value. A native popup button sizes to its longest option, which
/// leaves short values stranded at the left of a wide capsule.
struct ChoiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    /// Shown after the label in mono, e.g. the model id API clients send.
    var detail: (Value) -> String? = { _ in nil }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? title)
                if let d = detail(selection) { Text(d).font(.mono(.caption)).foregroundStyle(.secondary) }
            }
        }
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The work area's surface: frosted Liquid Glass with a tint, so the desktop shows through as soft tone, never as
/// readable text from other windows.
struct WorkAreaGlass: NSViewRepresentable {
    /// Its own type so the sidebar restyle in WindowGlass skips it.
    final class View: NSGlassEffectView {}
    var tint: Double
    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = View()
        v.style = .regular
        v.cornerRadius = 0
        return v
    }
    func updateNSView(_ v: NSGlassEffectView, context: Context) {
        v.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(tint)
    }
}

/// A live status line with its bar: determinate when the engine reports a fraction, indeterminate otherwise.
struct LiveProgress: View {
    let label: String
    var fraction: Double?
    /// nil lets the bar fill its container (the progress strip over a running placeholder).
    var barMaxWidth: CGFloat? = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout).foregroundStyle(Color.live).monospacedDigit()
            Group {
                if let fraction { ProgressView(value: min(max(fraction, 0), 1)) } else { ProgressView() }
            }
            .progressViewStyle(.linear).tint(Color.live).frame(maxWidth: barMaxWidth ?? .infinity)
        }
        .accessibilityElement(children: .combine)
    }

    /// A full-width glass strip along the bottom of a running placeholder (Images, Video).
    func strip() -> some View {
        LiveProgress(label: label, fraction: fraction, barMaxWidth: nil)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12)).padding(12)
    }
}

extension View {
    /// Composer keys, the same in every pane: Return submits (the field's onSubmit); ⌘↩ or ⌃↩ inserts a line break
    /// at the cursor, as ⌥↩ already does in AppKit text fields.
    func composerKeys() -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) || press.modifiers.contains(.control) else { return .ignored }
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }
}
