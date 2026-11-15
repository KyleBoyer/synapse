import AppKit
import SwiftUI
import SynapseCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The server and folder watcher keep working from the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum Pane: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe", chat = "Chat", images = "Images", models = "Models", memory = "Memory", watch = "Watch Folders", server = "Server"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .transcribe: "waveform"
        case .chat: "bubble.left.and.text.bubble.right"
        case .images: "photo.on.rectangle.angled"
        case .memory: "memorychip"
        case .models: "square.and.arrow.down"
        case .watch: "folder.badge.gearshape"
        case .server: "network"
        }
    }
}

@main
struct SynapseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Synapse", id: "main") {
            MainView().environment(state).frame(minWidth: 820, minHeight: 520)
        }
        Settings {
            SettingsView().environment(state)
        }
        MenuBarExtra("Synapse", systemImage: "waveform") {
            MenuBarView().environment(state)
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var pane: Pane? = .transcribe

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch pane ?? .transcribe {
            case .transcribe: TranscribeView()
            case .chat: ChatView()
            case .images: ImagesView()
            case .models: ModelsView()
            case .memory: MemoryView()
            case .watch: WatchFoldersView()
            case .server: ServerView()
            }
        }
        .safeAreaInset(edge: .top) {
            if let e = state.startupError {
                Text(e).font(.callout).padding(6).frame(maxWidth: .infinity).background(.red.opacity(0.15))
            }
        }
    }
}
