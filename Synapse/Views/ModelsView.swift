import SwiftUI
import SynapseCore

struct ModelsView: View {
    var openPane: (Pane) -> Void = { _ in }
    @Environment(AppState.self) private var state
    @State private var selection: String? = "qwen3.5-0.8b"
    @State private var confirmDelete: ModelSpec?
    @State private var adding = false

    /// Catalog families in the order this pane lists them.
    private var families: [(String, [ModelSpec])] {
        let all: [(String, [ModelSpec])] = [("Added from Hugging Face", Catalog.custom),
         ("Transcription · Parakeet", Catalog.builtIn.filter { $0.engine == .parakeet }),
         ("Transcription · Whisper", Catalog.builtIn.filter { $0.engine == .whisper }),
         ("Chat and vision · Qwen3.5", Catalog.builtIn.filter { $0.engine == .mlx }),
         ("Images", Catalog.builtIn.filter(\.isImage)),
         ("Realtime speech", Catalog.builtIn.filter { $0.engine == .speech }),
         ("Full duplex", Catalog.builtIn.filter { $0.engine == .duplex }),
         ("Embeddings and rerankers", Catalog.builtIn.filter { $0.isEmbedding || $0.isReranker }),
         ("Video generation", Catalog.builtIn.filter(\.isVideoGen)),
         ("Sound generation", Catalog.builtIn.filter(\.isAudioGen)),
         ("Omni (mlx-vlm)", Catalog.builtIn.filter { $0.engine == .mlxvlm })]
        return all.filter { !$0.1.isEmpty }  // a family appears once its first model is in the catalog
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(families, id: \.0) { family in
                    Section(family.0) { ForEach(family.1) { row($0).tag($0.id) } }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(width: 300)
            Divider()
            if let spec = selection.flatMap(Catalog.spec) {
                ScrollView { Datasheet(spec: spec, openPane: openPane, confirmDelete: $confirmDelete).padding(28) }
                    .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("Select a model", systemImage: "cube.transparent").frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem {
                Button("Add from Hugging Face…", systemImage: "plus") { adding = true }.help("Add any model from Hugging Face")
            }
        }
        .sheet(isPresented: $adding) { AddModelSheet { selection = $0 } }
        #if DEBUG
        // `-addModel <org/name>` opens the sheet with the repo filled in and checked, for captures.
        .onAppear { if UserDefaults.standard.string(forKey: "addModel") != nil { adding = true } }
        #endif
        .task { await state.refreshModels() }
        .confirmationDialog("Delete \(confirmDelete?.displayName ?? "")?", isPresented: .constant(confirmDelete != nil),
                            presenting: confirmDelete) { spec in
            Button("Delete", role: .destructive) { state.delete(spec.id); confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { spec in Text("This removes \(sizeText(spec)) from the models folder. Its measurements are kept.") }
    }

    private func row(_ spec: ModelSpec) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.displayName).lineLimit(1)
                Text(spec.id).font(.mono(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch state.modelStates[spec.id] ?? .notDownloaded {
            case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Downloaded")
            case .downloading(let p): ProgressView(value: p).tint(.live).frame(width: 44).accessibilityLabel("Downloading")
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Failed")
            case .notDownloaded: Text(sizeText(spec)).font(.mono(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}

func sizeText(_ spec: ModelSpec) -> String {
    spec.approxMB >= 1000 ? String(format: "%.1f GB", Double(spec.approxMB) / 1000) : "\(spec.approxMB) MB"
}

/// One model's sheet: what it is, its measured characteristics on this Mac, and how to call it.
struct Datasheet: View {
    @Environment(AppState.self) private var state
    let spec: ModelSpec
    let openPane: (Pane) -> Void
    @Binding var confirmDelete: ModelSpec?

    private var metrics: [Metric] {
        if spec.isTTS { return [.ttsFirstAudio, .ttsSpeed] }
        if spec.isEmbedding { return [.embedRate] }
        if spec.isReranker { return [] }
        if spec.isVideoGen { return [.videoTime] }
        if spec.isAudioGen { return [.soundSpeed] }
        if spec.isChat { return [.firstToken, .decodeRate, .prefillRate, .firstAudio] }
        if spec.isTranscription { return [.realtimeSpeed] }
        if spec.isImage { return [.secondsPerStep, .imageTime] }
        return [.firstAudio]
    }
    private var tryPane: Pane? {
        if spec.isTTS { return .audio }
        if spec.isEmbedding || spec.isReranker { return .embed }
        if spec.isVideoGen { return .video }
        if spec.isAudioGen { return .audio }
        if spec.isChat { return .chat }
        if spec.isTranscription { return .transcribe }
        if spec.isImage { return .images }
        if spec.engine == .speech || spec.engine == .duplex { return .live }
        return nil
    }
    private var api: [String] {
        if spec.isTTS { return ["POST /v1/audio/speech", "GET /v1/realtime?model=\(spec.id)"] }
        if spec.isEmbedding { return ["POST /v1/embeddings"] }
        if spec.isReranker { return ["POST /v1/rerank"] }
        if spec.isVideoGen { return ["POST /v1/videos", "GET /v1/videos/{id}/content"] }
        if spec.isAudioGen { return ["POST /v1/audio/generations"] }
        if spec.isChat { return ["POST /v1/responses", "POST /v1/messages", "POST /v1/chat/completions"] }
        if spec.isTranscription { return ["POST /v1/audio/transcriptions", "POST /v1/audio/translations", "POST /asr"] }
        if spec.isImage { return ["POST /v1/images/generations"] + (spec.canEditImages ? ["POST /v1/images/edits"] : []) }
        return ["GET /v1/realtime?model=\(spec.id)"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            Divider()
            if !metrics.isEmpty { characteristics }
            VStack(alignment: .leading, spacing: 8) {
                Text("API").font(.headline)
                ForEach(api, id: \.self) { Text($0).font(.mono(.callout)).textSelection(.enabled) }
                Text("model: \(spec.id)").font(.mono(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.displayName).font(.largeTitle.weight(.bold))
                Text(spec.id).font(.mono(.title3)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 12) {
                    Text(summary)
                    Text(sizeText(spec)).font(.mono(.callout))
                    if let gb = spec.recommendedRAMGB { Text("needs ~\(gb) GB RAM").font(.mono(.callout)) }
                    if let r = state.resident(spec.id) { Text("loaded · \(gigabytes(r.bytes))").font(.mono(.callout)).foregroundStyle(Color.live) }
                }
                .font(.callout).foregroundStyle(.secondary)
                if spec.engine == .whisper, spec.variant == ModelStore.recommendedWhisperVariant {
                    Label("Recommended for this Mac", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.green)
                }
                if let gb = spec.recommendedRAMGB, UInt64(gb) * 1_073_741_824 > ProcessInfo.processInfo.physicalMemory {
                    Label("More than this Mac's memory: it will page heavily and run slowly.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            actions
        }
    }

    private var isCustom: Bool { Catalog.custom.contains { $0.id == spec.id } }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .trailing, spacing: 12) {
            switch state.modelStates[spec.id] ?? .notDownloaded {
            case .notDownloaded:
                Button("Download", systemImage: "arrow.down") { state.download(spec.id) }.buttonStyle(.glassProminent).controlSize(.large)
                if isCustom { Button("Remove from List", systemImage: "minus.circle") { state.removeCustom(spec.id) }.buttonStyle(.glass) }
            case .downloading(let p):
                HStack {
                    ProgressView(value: p).tint(.live).frame(width: 140)
                    Text("\(Int(p * 100))%").font(.mono(.callout)).foregroundStyle(Color.live)
                }
                Button("Cancel Download") { state.cancelDownload(spec.id) }.buttonStyle(.glass)
            case .ready:
                if spec.isTranscription {
                    if state.settings.defaultModelID == spec.id {
                        Label("Default for transcription", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { state.settings.defaultModelID = spec.id }.buttonStyle(.glass)
                            .help("Use for files, watched folders, whisper-1 and Bazarr when no model is named")
                    }
                }
                if let tryPane {
                    Button("Try in \(tryPane.rawValue)", systemImage: tryPane.icon) {
                        state.tryRequest = .init(pane: tryPane, modelID: spec.id)
                        openPane(tryPane)
                    }
                        .buttonStyle(.glassProminent).controlSize(.large)
                }
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = spec }.buttonStyle(.glass)
                if isCustom {
                    Button("Remove from List", systemImage: "minus.circle") { state.removeCustom(spec.id) }.buttonStyle(.glass)
                        .help("Delete its files and take it off the list")
                }
            case .failed(let msg):
                Text(msg).font(.callout).foregroundStyle(.red).frame(maxWidth: 260, alignment: .trailing).multilineTextAlignment(.trailing)
                HStack {
                    if msg.localizedCaseInsensitiveContains("gated") { Button("Add Token…") { state.showingSettings = true }.buttonStyle(.glass) }
                    Button("Retry") { state.download(spec.id) }.buttonStyle(.glassProminent)
                }
            }
        }
    }

    private var summary: String {
        if spec.isChat { return "Chat and vision" }
        if spec.isImage { return spec.canEditImages ? "Text to image and editing" : "Text to image" }
        if spec.engine == .duplex { return "Full-duplex speech" }
        if spec.engine == .speech { return "Realtime speech" }
        guard let l = spec.languages else { return "99 languages" + (spec.canTranslate ? ", translation" : "") }
        return l == ["en"] ? "English" : "\(l.count) languages"
    }

    private var characteristics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Characteristics on this Mac").font(.headline)
                Spacer()
                if metrics.contains(where: { state.metrics.stats(spec.id, $0) != nil }) {
                    Button("Reset Measurements") { state.metrics.clear(spec.id) }.buttonStyle(.borderless).font(.callout)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    Text("Parameter"); Text("Min").gridColumnAlignment(.trailing); Text("Typ").gridColumnAlignment(.trailing)
                    Text("Max").gridColumnAlignment(.trailing); Text("Unit"); Text("Runs").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(metrics) { m in
                    let s = state.metrics.stats(spec.id, m)
                    GridRow(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.label)
                            Text(m.conditions).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(s.map { m.format($0.min) } ?? "–").font(.mono())
                        Text(s.map { m.format($0.typ) } ?? "–").font(.mono(.body, weight: .bold))
                        Text(s.map { m.format($0.max) } ?? "–").font(.mono())
                        Text(m.unit).foregroundStyle(.secondary)
                        Text(s.map { "\($0.count)" } ?? "0").font(.mono()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footnote: String {
        let hasRuns = metrics.contains { state.metrics.stats(spec.id, $0) != nil }
        if !hasRuns, let tryPane { return "No runs yet. Try it in \(tryPane.rawValue) to measure it." }
        return "Typ is the median of the last 40 runs in this app. Requests from API clients are not measured here."
    }
}
