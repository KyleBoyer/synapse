import ServiceManagement
import SwiftUI
import SynapseCore

/// Settings as a sheet over the main window, built from the same glass panels and rows as the working panes.
struct SettingsView: View {
    @State private var historyBytes: Int?
    @State private var confirmingHistoryDelete = false
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WindowLook.appearanceKey) private var appearance: AppAppearance = .system
    @AppStorage(WindowLook.sidebarTintKey) private var sidebarTint = WindowLook.defaultSidebarTint
    @AppStorage(WindowLook.contentTintKey) private var contentTint = WindowLook.defaultContentTint
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        appearancePanel
                        generalPanel
                        memoryPanel
                        runningPanel.id("running")
                        historyPanel.id("history")
                        subtitlesPanel
                        storagePanel
                        voomPanel
                        aboutPanel
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
                #if DEBUG
                // `-settingsScrollTo running` brings that panel into view, for captures.
                .task { if let id = UserDefaults.standard.string(forKey: "settingsScrollTo") { proxy.scrollTo(id, anchor: .top) } }
                #endif
            }
        }
        .frame(width: 620, height: 560)
    }

    // MARK: Panels

    private var appearancePanel: some View {
        Panel("Appearance") {
            PanelRow("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: appearance) { NSApp.appearance = appearance.nsAppearance }
            }
            PanelRow("Sidebar transparency") { percentSlider(tint: $sidebarTint) }
            PanelRow("Content transparency") { percentSlider(tint: $contentTint) }
            HStack(alignment: .firstTextBaseline) {
                Text("How much of the desktop shows through. The content area is frosted, so what shows through stays soft.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Restore Defaults") {
                    sidebarTint = WindowLook.defaultSidebarTint; contentTint = WindowLook.defaultContentTint
                }
                .buttonStyle(.glass)
                .disabled(sidebarTint == WindowLook.defaultSidebarTint && contentTint == WindowLook.defaultContentTint)
            }
        }
    }

    private var generalPanel: some View {
        Panel("General") {
            PanelRow("Launch at login") {
                Toggle("Launch at login", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        }
    }

    private var memoryPanel: some View {
        @Bindable var state = state
        let budget = state.settings.memoryBudgetGB ?? Double(ramGB * 3 / 4)
        return Panel("Memory") {
            PanelRow("Model memory budget") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { budget }, set: { state.settings.memoryBudgetGB = $0.rounded() }),
                           in: 4...Double(max(5, ramGB)), step: 1)
                        .frame(width: 180)
                    Text("\(Int(budget)) GB").font(.mono(.callout)).frame(width: 52, alignment: .trailing)
                }
            }
            PanelRow("Unload idle models") {
                Picker("Unload idle models", selection: $state.settings.idleUnloadMinutes) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 15, 30, 60, 120], id: \.self) { Text("After \($0) min").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            HStack(alignment: .firstTextBaseline) {
                Text("This Mac has \(ramGB) GB. Over budget, idle models unload first; past it macOS pages to disk.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Use Default (75%)") { state.settings.memoryBudgetGB = nil }
                    .buttonStyle(.glass).disabled(state.settings.memoryBudgetGB == nil)
            }
        }
    }

    /// Prompt caching and KV precision, for every chat engine.
    private var runningPanel: some View {
        @Bindable var state = state
        return Panel("Running models") {
            PanelRow("Prompt cache memory") {
                Picker("Prompt cache memory", selection: $state.settings.promptCacheGB) {
                    Text("Automatic (\(gigabytes(ChatService.defaultPromptCacheBytes)))").tag(Double?.none)
                    ForEach([0.5, 1, 2, 4, 8], id: \.self) { Text(String(format: "%g GB", $0)).tag(Double?.some($0)) }
                }
                .labelsHidden().fixedSize()
            }
            PanelRow("Save prompts to disk") {
                Picker("Save prompts to disk", selection: $state.settings.diskCacheGB) {
                    Text("Off").tag(0.0)
                    ForEach([5.0, 10, 20, 50], id: \.self) { Text("Up to \(Int($0)) GB").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            PanelRow("KV cache precision") {
                Picker("KV cache precision", selection: $state.settings.kvPrecision) {
                    ForEach(KVPrecision.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Follow-up turns reuse the conversation so far instead of reading it again. 8-bit and 4-bit store "
                     + "attention in less memory for longer contexts, at a small quality cost; changing it unloads idle chat models.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Clear Cache") { state.clearPromptCache(nil, disk: true) }.buttonStyle(.glass)
            }
        }
    }

    /// Work done in the panes (never API requests): how long it stays, and deleting it.
    private var historyPanel: some View {
        @Bindable var state = state
        return Panel("History") {
            PanelRow("Keep history") {
                Picker("Keep history", selection: $state.settings.historyDays) {
                    Text("Forever").tag(Int?.none)
                    Text("90 days").tag(Int?.some(90))
                    Text("30 days").tag(Int?.some(30))
                    Text("7 days").tag(Int?.some(7))
                    Text("Off").tag(Int?.some(0))
                }
                .labelsHidden().fixedSize()
            }
            HStack(alignment: .firstTextBaseline) {
                Text(state.savesHistory
                     ? "Chats, images, clips, calls and transcripts made here are kept, \(historyBytes.map { byteSize($0) } ?? "…") so far. "
                       + "Requests from API clients are never saved."
                     : "Nothing new is saved. What was saved before stays until you delete it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([state.history.root]) }.buttonStyle(.glass)
                Button("Delete All…", role: .destructive) { confirmingHistoryDelete = true }.buttonStyle(.glass)
            }
        }
        .task(id: state.historyRevision) { historyBytes = await state.history.totalBytes() }
        .confirmationDialog("Delete all history?", isPresented: $confirmingHistoryDelete) {
            Button("Delete All", role: .destructive) { state.clearHistory(nil) }
        } message: { Text("Every saved chat, image, clip, call and transcript is deleted. This can't be undone.") }
    }

    private var subtitlesPanel: some View {
        @Bindable var state = state
        return Panel("Subtitles") {
            PanelRow("Characters per line") { stepper("\(state.settings.cue.maxLineChars)", $state.settings.cue.maxLineChars, 20...80) }
            PanelRow("Lines per cue") { stepper("\(state.settings.cue.maxLines)", $state.settings.cue.maxLines, 1...3) }
            PanelRow("Longest cue") {
                stepper(String(format: "%.0f s", state.settings.cue.maxDuration),
                        Binding(get: { Int(state.settings.cue.maxDuration) }, set: { state.settings.cue.maxDuration = Double($0) }), 2...15)
            }
        }
    }

    private var storagePanel: some View {
        Panel("Storage") {
            PathRow(label: "Models folder", path: state.settings.modelsRoot.path,
                    choose: { choose(directory: true, create: true) { state.settings.modelsFolder = $0 } },
                    reset: state.settings.modelsFolder == nil ? nil : ("Use Default", { state.settings.modelsFolder = nil }))
            Text("Restart Synapse to use a new folder. Existing models are not moved.").font(.caption).foregroundStyle(.secondary)
            PanelRow("Hugging Face token") {
                SecureField(HFDownloader.cliToken() == nil ? "For gated models" : "Using the hf CLI login", text: Binding(
                    get: { state.settings.hfToken ?? "" },
                    set: { state.settings.hfToken = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
        }
    }

    private var voomPanel: some View {
        Panel("vOOM: models larger than memory") {
            PathRow(label: "vOOM checkout", path: state.settings.voomCheckout ?? "Not set",
                    choose: { choose(directory: true, create: false) { state.settings.voomCheckout = $0 } },
                    reset: state.settings.voomCheckout == nil ? nil : ("Clear", { state.settings.voomCheckout = nil }))
            Text("Adds voom:<model> ids, served by vOOM's paging runtime from the SSD.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var aboutPanel: some View {
        Panel("About") {
            PanelRow("Synapse") { Text(Synapse.version).font(.mono(.callout)) }
            PanelRow("Check for updates automatically") {
                @Bindable var updates = state.updates
                HStack(spacing: 10) {
                    Button("Check Now") { updates.check() }.buttonStyle(.glass)
                    Toggle("Check for updates automatically", isOn: $updates.automatic).toggleStyle(.switch).labelsHidden()
                }
            }
            if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                PanelRow("Licenses") { Button("Third-Party Notices") { NSWorkspace.shared.open(url) }.buttonStyle(.glass) }
            }
        }
    }

    // MARK: Pieces

    /// Shown as transparency (what users think in); stored as the tint the glass carries.
    private func percentSlider(tint: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { 1 - tint.wrappedValue }, set: { tint.wrappedValue = 1 - $0 }), in: 0...1)
                .frame(width: 180)
            Text("\(Int(((1 - tint.wrappedValue) * 100).rounded()))%").font(.mono(.callout)).frame(width: 52, alignment: .trailing)
        }
    }

    private func stepper(_ value: String, _ binding: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(value).font(.mono(.callout)).frame(width: 52, alignment: .trailing)
            Stepper(value, value: binding, in: range).labelsHidden()
        }
    }

    private func choose(directory: Bool, create: Bool, _ apply: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.canCreateDirectories = create
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }
}

/// A titled glass panel, the same surface as the burn-in readout.
struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// A folder setting: the path in mono on its own line, actions flush right.
private struct PathRow: View {
    let label: String
    let path: String
    let choose: () -> Void
    let reset: (String, () -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                if let reset { Button(reset.0, action: reset.1).buttonStyle(.glass) }
                Button("Choose…", action: choose).buttonStyle(.glass)
            }
            Text(path).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
