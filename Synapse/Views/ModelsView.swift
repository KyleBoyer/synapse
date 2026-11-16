import SwiftUI
import SynapseCore

struct ModelsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmDelete: ModelSpec?
    private let recommendedVariant = ModelStore.recommendedWhisperVariant

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Picker("Default model", selection: $state.settings.defaultModelID) {
                    ForEach(state.downloadedSpecs) { Text($0.displayName).tag($0.id) }
                    if !state.downloadedSpecs.contains(where: { $0.id == state.settings.defaultModelID }) {
                        Text("\(state.settings.defaultModelID) (not downloaded)").tag(state.settings.defaultModelID)
                    }
                }
            }
            Section("Parakeet (fast, 25 European languages)") {
                ForEach(Catalog.all.filter { $0.engine == .parakeet }) { row($0) }
            }
            Section("Whisper (99 languages, translation)") {
                ForEach(Catalog.all.filter { $0.engine == .whisper }) { row($0) }
            }
            Section("Qwen3.5 (chat + vision, MLX)") {
                ForEach(Catalog.all.filter { $0.engine == .mlx }) { row($0) }
            }
            Section("Realtime (live captions, voice, full duplex)") {
                ForEach(Catalog.all.filter { $0.engine == .speech || $0.engine == .duplex }) { row($0) }
            }
            Section("Images") {
                ForEach(Catalog.all.filter(\.isImage)) { row($0) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
        .task { await state.refreshModels() }
        .confirmationDialog("Delete \(confirmDelete?.displayName ?? "")?", isPresented: .constant(confirmDelete != nil),
                            presenting: confirmDelete) { spec in
            Button("Delete", role: .destructive) { state.delete(spec.id); confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    private func row(_ spec: ModelSpec) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(spec.displayName)
                    if spec.engine == .whisper, spec.variant == recommendedVariant {
                        Text("Recommended for this Mac").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.2), in: Capsule())
                    }
                }
                Text("~\(spec.approxMB) MB · \(languageSummary(spec))").font(.caption).foregroundStyle(.secondary)
                if let gb = spec.recommendedRAMGB, UInt64(gb) * 1_073_741_824 > ProcessInfo.processInfo.physicalMemory {
                    Text("Needs ~\(gb) GB RAM; will page heavily on this Mac").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            switch state.modelStates[spec.id] ?? .notDownloaded {
            case .notDownloaded:
                Button("Download") { state.download(spec.id) }
            case .downloading(let p):
                ProgressView(value: p).frame(width: 120)
                Button("Cancel", systemImage: "xmark.circle") { state.cancelDownload(spec.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Delete", systemImage: "trash") { confirmDelete = spec }.labelStyle(.iconOnly).buttonStyle(.borderless)
            case .failed(let msg):
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 220)
                if msg.localizedCaseInsensitiveContains("gated") { SettingsLink { Text("Open Settings") } }
                Button("Retry") { state.download(spec.id) }
            }
        }
    }

    private func languageSummary(_ spec: ModelSpec) -> String {
        if spec.isChat { return "Chat + images" }
        if spec.isImage { return spec.canEditImages ? "Text to image + editing" : "Text to image" }
        guard let l = spec.languages else { return "99 languages" }
        return l == ["en"] ? "English" : "\(l.count) languages"
    }
}
