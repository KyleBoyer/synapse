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

    #if DEBUG
    /// `-composerKeyTest YES`: sends ⌘↩, ⌃↩ and Return to this app's own focused composer (never to other apps) and
    /// prints what each did, so the composer keys can be checked without typing.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults.standard.bool(forKey: "composerKeyTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return print("composerKeyTest: no window") }
            window.makeKeyAndOrderFront(nil)
            guard let field = window.firstResponder as? NSTextView else { return print("composerKeyTest: no focused field") }
            @MainActor func press(_ flags: NSEvent.ModifierFlags) async {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { NSApp.sendEvent(e) }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            field.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
            await press(.command)
            print("composerKeyTest: after ⌘↩ \(field.string.debugDescription)")
            field.insertText("second", replacementRange: NSRange(location: NSNotFound, length: 0))
            await press(.control)
            print("composerKeyTest: after ⌃↩ \(field.string.debugDescription)")
            await press([])
            print("composerKeyTest: after ↩ \(field.string.debugDescription)")
        }
    }
    #endif

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
                // With the window closed Synapse lives in the menu bar only: no Dock icon, no app menus. Opening the
                // window again (from the menu bar) brings the Dock icon back.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
                #if DEBUG
                // `-closeWindowAfter <seconds>` closes the main window as its close button would, for checks.
                .task {
                    let after = UserDefaults.standard.double(forKey: "closeWindowAfter")
                    guard after > 0 else { return }
                    try? await Task.sleep(for: .seconds(after))
                    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Synapse" }?.performClose(nil)
                }
                #endif
        }
        .commands {
            CommandGroup(replacing: .appSettings) { SettingsCommand().environment(state) }
            CommandGroup(after: .appInfo) { CheckForUpdatesCommand().environment(state) }
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
            .background {
                // The sidebar's own glass samples the desktop even in an opaque window (seen in Dark appearance).
                if sidebarTint >= WindowLook.solid { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
            }
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
            // Fill the column before the background: panes that size to their content (Video's empty state, Memory's
            // centered column) otherwise get the work-area glass only behind that content, and the rest shows the desktop.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // The detail column extends under the floating sidebar; keep its leading safe area so the work area's
                // blur stops at the sidebar's edge instead of painting the clear sidebar solid.
                Group {
                    // Fully tinted glass is still see-through in Dark appearance; 0% transparency means solid.
                    if contentTint >= WindowLook.solid { Color(nsColor: .windowBackgroundColor) } else { WorkAreaGlass(tint: contentTint) }
                }
                .ignoresSafeArea(edges: [.top, .bottom, .trailing])
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: state.handoff) { if let h = state.handoff { pane = h.pane } }
        #if DEBUG
        // `-tryModel <id>` does what Models' "Try in" button does, a moment after launch, for checks.
        .task {
            guard let id = UserDefaults.standard.string(forKey: "tryModel"), let spec = Catalog.spec(id) else { return }
            try? await Task.sleep(for: .seconds(2))
            let target: Pane = spec.isChat ? .chat : spec.isImage ? .images : spec.isVideoGen ? .video : spec.isEmbedding ? .embed : .audio
            state.tryRequest = .init(pane: target, modelID: id)
            pane = target
        }
        // `-openSettings YES` opens Settings after launch, for captures.
        .task { if UserDefaults.standard.bool(forKey: "openSettings") { state.showingSettings = true } }
        #endif
        .containerBackground(.clear, for: .window)
        .sheet(isPresented: Binding(get: { state.showingSettings }, set: { state.showingSettings = $0 })) {
            SettingsView().environment(state)
        }
        .background {
            WindowGlass(sidebarTint: sidebarTint, solidWindow: sidebarTint >= WindowLook.solid && contentTint >= WindowLook.solid).ignoresSafeArea()
        }
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
                let approx = state.residents.contains { !$0.measured } ? "≈" : ""
                Text("\(approx)\(String(format: "%.1f", Double(used) / 1_073_741_824)) / \(gigabytes(budget)) loaded")
                    .font(.mono(.caption2)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if used > budget { Text("over budget").font(.mono(.caption2)).foregroundStyle(.orange) }
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
