import AppKit
import SwiftUI
import SynapseCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Settings > Appearance; `-appearance Dark` on the command line also works (UserDefaults reads launch arguments).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppAppearance.stored.nsAppearance
    }

    // The server and folder watcher keep working from the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-generation crashed: exit() runs MLX's C++ static destructors, which free the Metal device while a
    /// background thread is still evaluating on it. With GPU work in flight, end the process without them; the OS
    /// reclaims GPU memory, and the server sidecars stop on their own when this process is gone.
    func applicationWillTerminate(_ notification: Notification) {
        guard GPUGate.shared.isBusy else { return }
        UserDefaults.standard.synchronize()
        _exit(0)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe", chat = "Chat", images = "Images", video = "Video", audio = "Audio", embed = "Embed", live = "Live", models = "Models", memory = "Memory", watch = "Watch Folders", server = "Server"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .transcribe: "waveform"
        case .chat: "bubble.left.and.text.bubble.right"
        case .images: "photo.on.rectangle.angled"
        case .video: "film"
        case .audio: "speaker.wave.2"
        case .embed: "point.3.connected.trianglepath.dotted"
        case .memory: "memorychip"
        case .live: "waveform.and.mic"
        case .models: "cube.transparent"
        case .watch: "folder.badge.gearshape"
        case .server: "network"
        }
    }
    /// Try: run a model and watch it. Run: what keeps it served.
    static let tryPanes: [Pane] = [.transcribe, .chat, .images, .video, .audio, .embed, .live]
    static let runPanes: [Pane] = [.models, .memory, .watch, .server]
}

@main
struct SynapseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Synapse", id: "main") {
            MainView().environment(state).frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .appSettings) { SettingsCommand().environment(state) }
        }
        MenuBarExtra("Synapse", systemImage: "waveform") {
            MenuBarView().environment(state)
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var state
    // `-initialPane Models` on the command line opens a pane directly (UserDefaults reads launch arguments).
    @State private var pane: Pane? = UserDefaults.standard.string(forKey: "initialPane").flatMap(Pane.init(rawValue:)) ?? .chat
    @AppStorage(WindowLook.sidebarTintKey) private var sidebarTint = WindowLook.defaultSidebarTint
    @AppStorage(WindowLook.contentTintKey) private var contentTint = WindowLook.defaultContentTint

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Try") { ForEach(Pane.tryPanes) { row($0) } }
                Section("Run") { ForEach(Pane.runPanes) { row($0) } }
            }
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarFooter().padding(10) }
        } detail: {
            Group {
                switch pane ?? .chat {
                case .transcribe: TranscribeView()
                case .chat: ChatView()
                case .images: ImagesView()
                case .audio: AudioView()
                case .embed: EmbedView()
                case .video: VideoView()
                case .live: LiveView()
                case .models: ModelsView(openPane: { pane = $0 })
                case .memory: MemoryView()
                case .watch: WatchFoldersView()
                case .server: ServerView()
                }
            }
            .scrollContentBackground(.hidden)
            .background {
                // The detail column extends under the floating sidebar; keep its leading safe area so the work area's
                // blur stops at the sidebar's edge instead of painting the clear sidebar solid.
                WorkAreaGlass(tint: contentTint)
                    .ignoresSafeArea(edges: [.top, .bottom, .trailing])
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #if DEBUG
        // `-tryModel <id>` does what Models' "Try in" button does, a moment after launch, for checks.
        .task {
            guard let id = UserDefaults.standard.string(forKey: "tryModel"), let spec = Catalog.spec(id) else { return }
            try? await Task.sleep(for: .seconds(2))
            let target: Pane = spec.isChat ? .chat : spec.isImage ? .images : spec.isVideoGen ? .video : .audio
            state.tryRequest = .init(pane: target, modelID: id)
            pane = target
        }
        #endif
        .containerBackground(.clear, for: .window)
        .sheet(isPresented: Binding(get: { state.showingSettings }, set: { state.showingSettings = $0 })) {
            SettingsView().environment(state)
        }
        .background { WindowGlass(sidebarTint: sidebarTint).ignoresSafeArea() }
        .safeAreaInset(edge: .top) {
            if let e = state.startupError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .padding(8).frame(maxWidth: .infinity).glassEffect(.regular, in: .rect(cornerRadius: 12)).padding(.horizontal)
            }
        }
    }

    private func row(_ p: Pane) -> some View {
        Label {
            HStack {
                Text(p.rawValue)
                Spacer()
                if state.isActive(p) { LiveDot() }
            }
        } icon: { Image(systemName: p.icon).foregroundStyle(.secondary) }
        .tag(p)
    }
}

/// Server address and loaded memory, always in view.
struct SidebarFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let used = state.residents.reduce(0) { $0 + $1.bytes }
        let budget = state.settings.modelManagerConfig.budgetBytes
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(serverColor).frame(width: 7, height: 7)
                Text(serverText).font(.mono(.caption)).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(min(used, budget)), total: Double(max(budget, 1)))
                    .tint(used > budget ? .orange : state.residents.contains { $0.leases > 0 } ? Color.live : .secondary)
                Text("\(gigabytes(used)) of \(gigabytes(budget)) loaded").font(.mono(.caption2)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var serverText: String {
        switch state.serverStatus {
        case .running: "\(state.settings.allowLAN ? "0.0.0.0" : "127.0.0.1"):\(state.settings.port)"
        default: state.serverStatus.label
        }
    }
    private var serverColor: Color {
        switch state.serverStatus {
        case .running: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

/// ⌘, opens the Settings sheet on the main window, bringing the window back if it was closed.
struct SettingsCommand: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") {
            openWindow(id: "main")
            state.showingSettings = true
        }
        .keyboardShortcut(",")
    }
}
