import SwiftUI
import SynapseCore

/// A toolbar button that lists saved work of one kind: open one, delete one or several (⌫), or clear them all.
struct HistoryButton: View {
    let kind: HistoryKind
    /// Singular noun for the items ("chat", "call", "transcript").
    let noun: String
    let open: (HistoryItem) -> Void
    @State private var showing = false

    var body: some View {
        Button("History", systemImage: "clock.arrow.circlepath") { showing = true }
            .help("Earlier \(noun)s")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                HistoryList(kind: kind, noun: noun) { open($0); showing = false }
            }
            #if DEBUG
            // `-openHistory chat|call|transcript|embed` opens that list after launch, for captures.
            .task {
                guard UserDefaults.standard.string(forKey: "openHistory") == kind.rawValue else { return }
                try? await Task.sleep(for: .seconds(1))
                showing = true
                // With -openFirstHistory the list opens the newest item and closes; show it again over the result.
                guard UserDefaults.standard.bool(forKey: "openFirstHistory") else { return }
                try? await Task.sleep(for: .seconds(2))
                showing = true
            }
            #endif
    }
}

struct HistoryList: View {
    #if DEBUG
    @MainActor static var debugDeleted = false
    @MainActor static var debugOpened = false
    #endif
    let kind: HistoryKind
    let noun: String
    let open: (HistoryItem) -> Void
    @Environment(AppState.self) private var state
    @State private var items: [HistoryItem] = []
    @State private var selection = Set<UUID>()
    @State private var query = ""
    @State private var confirming: [UUID]?

    private var shown: [HistoryItem] {
        query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.model.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search \(noun)s", text: $query).textFieldStyle(.roundedBorder).padding(10)
            if items.isEmpty {
                Text(state.savesHistory ? "No saved \(noun)s yet." : "History is off in Settings.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(shown, selection: $selection) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title.isEmpty ? "Untitled" : item.title).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(item.model).font(.mono(.caption))
                            Text(item.updatedAt, format: .relative(presentation: .named)).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(item.id)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let item = items.first(where: { ids.contains($0.id) }) { Button("Open") { open(item) } }
                    Button(ids.count > 1 ? "Delete \(ids.count) \(noun)s" : "Delete", role: .destructive) { confirming = Array(ids) }
                } primaryAction: { ids in
                    if let item = items.first(where: { ids.contains($0.id) }) { open(item) }
                }
                .onDeleteCommand { if !selection.isEmpty { confirming = Array(selection) } }
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Text("\(items.count) saved").font(.mono(.caption)).foregroundStyle(.secondary)
                Spacer()
                Button("Delete", role: .destructive) { confirming = Array(selection) }.disabled(selection.isEmpty)
                Button("Clear All…", role: .destructive) { confirming = items.map(\.id) }.disabled(items.isEmpty)
            }
            .buttonStyle(.borderless).padding(10)
        }
        .frame(width: 340, height: 420)
        .task(id: state.historyRevision) {
            items = await state.history.list(kind)
            #if DEBUG
            // `-openFirstHistory YES` (with `-openHistory`) opens the newest item, to capture a restore.
            if UserDefaults.standard.bool(forKey: "openFirstHistory"), !Self.debugOpened, let first = items.first {
                Self.debugOpened = true
                open(first)
            }
            // `-deleteFirstHistory YES` deletes the newest item the way the confirmed Delete does.
            if UserDefaults.standard.bool(forKey: "deleteFirstHistory"), !Self.debugDeleted, let first = items.first {
                Self.debugDeleted = true   // the launch argument stays set, so delete once per launch
                state.deleteHistory([first.id], kind: kind)
            }
            #endif
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Delete", role: .destructive) {
                if let ids = confirming { state.deleteHistory(ids, kind: kind); selection.subtract(ids) }
                confirming = nil
            }
        } message: { Text("This can't be undone.") }
    }

    private var deleteTitle: String {
        let n = confirming?.count ?? 0
        return n == 1 ? "Delete this \(noun)?" : "Delete \(n) \(noun)s?"
    }
}

/// "Clear History…" for panes whose saved items appear inline (Images, Audio, Video), with a confirmation.
/// `clear` deletes the pane's items (from history and from view).
struct ClearHistoryButton: View {
    let noun: String
    let clear: () -> Void
    @State private var confirming = false

    var body: some View {
        Button("Clear History…", systemImage: "trash") { confirming = true }
            .help("Delete every saved \(noun) shown here")
            .confirmationDialog("Delete every saved \(noun)?", isPresented: $confirming) {
                Button("Delete All", role: .destructive, action: clear)
            } message: { Text("This can't be undone.") }
    }
}

/// "Delete…" with a confirmation, for one item shown inline.
struct DeleteItemMenu: View {
    let noun: String
    let delete: () -> Void
    @State private var confirming = false

    var body: some View {
        Menu("More", systemImage: "ellipsis") { Button("Delete…", role: .destructive) { confirming = true } }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).labelStyle(.iconOnly).fixedSize()
            .confirmationDialog("Delete this \(noun)?", isPresented: $confirming) {
                Button("Delete", role: .destructive, action: delete)
            } message: { Text("This can't be undone.") }
    }
}
