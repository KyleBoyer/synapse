import ServiceManagement
import SwiftUI
import SynapseCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(WindowLook.appearanceKey) private var appearance: AppAppearance = .system
    @AppStorage(WindowLook.sidebarTintKey) private var sidebarTint = WindowLook.defaultSidebarTint
    @AppStorage(WindowLook.contentTintKey) private var contentTint = WindowLook.defaultContentTint
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var state = state
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { NSApp.appearance = appearance.nsAppearance }
                transparencyRow("Sidebar transparency", tint: $sidebarTint)
                transparencyRow("Content transparency", tint: $contentTint)
                HStack {
                    Text("How much of the desktop shows through the window. The content area is frosted, so what shows through stays soft.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        sidebarTint = WindowLook.defaultSidebarTint; contentTint = WindowLook.defaultContentTint
                    }
                    .disabled(sidebarTint == WindowLook.defaultSidebarTint && contentTint == WindowLook.defaultContentTint)
                }
            }
            Section("Subtitles") {
                Stepper("Max characters per line: \(state.settings.cue.maxLineChars)",
                        value: $state.settings.cue.maxLineChars, in: 20...80)
                Stepper("Max lines per cue: \(state.settings.cue.maxLines)", value: $state.settings.cue.maxLines, in: 1...3)
                Stepper(String(format: "Max cue duration: %.0f s", state.settings.cue.maxDuration),
                        value: $state.settings.cue.maxDuration, in: 2...15, step: 1)
            }
            Section("Memory") {
                let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
                Toggle("Default (75%)", isOn: Binding(
                    get: { state.settings.memoryBudgetGB == nil },
                    set: { state.settings.memoryBudgetGB = $0 ? nil : Double(ramGB * 3 / 4) }))
                if let gb = state.settings.memoryBudgetGB {
                    Stepper("Model memory budget: \(Int(gb)) GB",
                            value: Binding(get: { Int(gb) }, set: { state.settings.memoryBudgetGB = Double($0) }),
                            in: 4...max(4, ramGB), step: 1)
                }
                Stepper(state.settings.idleUnloadMinutes == 0 ? "Unload idle models: never" : "Unload idle models after \(state.settings.idleUnloadMinutes) min",
                        value: Binding(get: { state.settings.idleUnloadMinutes },
                                       set: { state.settings.idleUnloadMinutes = $0 < 5 ? 0 : min($0, 120) }),
                        in: 4...120, step: 1)
            }
            Section("Storage") {
                LabeledContent("Models folder") { Text(state.settings.modelsRoot.path).font(.mono(.callout)).textSelection(.enabled) }
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { state.settings.modelsFolder = url.path }
                    }
                    Button("Use Default") { state.settings.modelsFolder = nil }
                        .disabled(state.settings.modelsFolder == nil)
                }
                Text("Restart Synapse to use the new folder; existing models are not moved")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Hugging Face token (for gated models)", text: Binding(
                    get: { state.settings.hfToken ?? "" },
                    set: { state.settings.hfToken = $0.isEmpty ? nil : $0 }))
            }
            Section("vOOM (models larger than memory)") {
                LabeledContent("vOOM checkout") { Text(state.settings.voomCheckout ?? "Not set").font(.mono(.callout)).textSelection(.enabled) }
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { state.settings.voomCheckout = url.path }
                    }
                    Button("Clear") { state.settings.voomCheckout = nil }
                        .disabled(state.settings.voomCheckout == nil)
                }
                Text("Adds voom:<model> ids, served by vOOM's paging runtime from the SSD")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Synapse \(Synapse.version)")
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                    Button("Third-party notices") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    /// Shown as transparency (what users think in); stored as the tint the glass carries.
    private func transparencyRow(_ label: String, tint: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(get: { 1 - tint.wrappedValue }, set: { tint.wrappedValue = 1 - $0 }), in: 0...1)
                    .frame(width: 180)
                Text("\(Int(((1 - tint.wrappedValue) * 100).rounded()))%").font(.mono(.callout)).frame(width: 44, alignment: .trailing)
            }
        }
    }
}
