import SwiftUI
import SynapseCore

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let current = state.jobs.first(where: { !$0.status.isTerminal && $0.status != .queued }) {
            Text("\(current.request.input.url.lastPathComponent): \(current.status.label)")
        }
        let queued = state.jobs.filter { $0.status == .queued }.count
        Text(queued == 0 ? "Queue empty" : "\(queued) queued")
        Text(state.serverStatus.label)
        Divider()
        Button("Open Synapse") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Settings…") {
            openWindow(id: "main")
            NSApp.activate()
            state.showingSettings = true
        }
        Toggle("Pause Watching", isOn: Binding(
            get: { state.settings.watchingPaused },
            set: { state.settings.watchingPaused = $0 }))
        Divider()
        Button("Quit Synapse") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
