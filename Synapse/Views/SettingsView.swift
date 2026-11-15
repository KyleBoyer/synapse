import ServiceManagement
import SwiftUI
import SynapseCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
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
            Section("Subtitles") {
                Stepper("Max characters per line: \(state.settings.cue.maxLineChars)",
                        value: $state.settings.cue.maxLineChars, in: 20...80)
                Stepper("Max lines per cue: \(state.settings.cue.maxLines)", value: $state.settings.cue.maxLines, in: 1...3)
                Stepper(String(format: "Max cue duration: %.0f s", state.settings.cue.maxDuration),
                        value: $state.settings.cue.maxDuration, in: 2...15, step: 1)
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
}
