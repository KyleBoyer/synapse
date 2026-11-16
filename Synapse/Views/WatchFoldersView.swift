import SwiftUI
import SynapseCore

struct WatchFoldersView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle("Pause watching", isOn: $state.settings.watchingPaused)
                Text("New media in these folders gets a subtitle file next to it (Movie.en.srt). Files that already have one are skipped. Folders are rescanned every 10 minutes, which catches files added from other machines on network shares.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Folders") {
                if state.settings.watchFolders.isEmpty {
                    Text("No watched folders").foregroundStyle(.secondary)
                }
                ForEach($state.settings.watchFolders) { $folder in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "folder")
                            Text(folder.path).font(.mono(.callout)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(counts(folder)).font(.mono(.caption)).foregroundStyle(.secondary)
                            Button("Remove", systemImage: "minus.circle") {
                                state.settings.watchFolders.removeAll { $0.path == folder.path }
                            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        HStack {
                            ModelPicker(title: "Model", specs: state.downloadedSpecs, id: $folder.modelID)
                            LanguagePicker(title: "Language", code: $folder.language)
                            Picker("Task", selection: $folder.task) {
                                Text("Transcribe").tag(TaskKind.transcribe)
                                Text("Translate").tag(TaskKind.translate)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Watch Folders")
        .toolbar { Button("Add Folder…", systemImage: "plus") { add() } }
    }

    private func counts(_ folder: WatchFolder) -> String {
        let jobs = state.jobs.filter { $0.request.origin == .watcher && $0.request.input.url.path.hasPrefix(folder.path + "/") }
        let done = jobs.filter { $0.status == .done }.count
        let active = jobs.filter { !$0.status.isTerminal }.count
        return jobs.isEmpty ? "" : "\(active) queued · \(done) done"
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !state.settings.watchFolders.contains(where: { $0.path == url.path }) {
            state.settings.watchFolders.append(WatchFolder(path: url.path))
        }
    }
}
