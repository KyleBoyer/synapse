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
         ("Video generation", Catalog.builtIn.filter { $0.engine == .videogen }),
         ("Sound generation", Catalog.builtIn.filter(\.isAudioGen)),
         ("Audio cleanup and separation", Catalog.builtIn.filter(\.isAudioEdit)),
         ("Depth and upscaling", Catalog.builtIn.filter { $0.engine == .imagetool }),
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
                ScrollViewReader { proxy in
                    ScrollView { Datasheet(spec: spec, openPane: openPane, confirmDelete: $confirmDelete).padding(28) }
                        .frame(maxWidth: .infinity)
                        #if DEBUG
                        // `-datasheetScrollTo running` scrolls a datasheet to its Running section, for captures.
                        .task(id: spec.id) {
                            guard let id = UserDefaults.standard.string(forKey: "datasheetScrollTo") else { return }
                            try? await Task.sleep(for: .seconds(1))
                            proxy.scrollTo(id, anchor: .top)
                        }
                        #endif
                }
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
        // `-selectModel <id>` opens that model's datasheet.
        .onAppear { if let id = UserDefaults.standard.string(forKey: "selectModel") { selection = id } }
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
    /// Smaller models with the same tokenizer that can draft for this one (speculative decoding).
    @State private var drafts: [ModelSpec] = []

    private var metrics: [Metric] {
        if spec.isTTS { return [.ttsFirstAudio, .ttsSpeed] }
        if spec.isEmbedding { return [.embedRate] }
        if spec.isReranker || spec.isAddOn { return [] }
        if spec.isVideoGen { return [.videoTime] }
        if spec.isAudioGen { return [.soundSpeed] }
        if spec.isAudioEdit || spec.engine == .imagetool { return [] }
        if spec.isChat { return [.loadTime, .firstToken, .firstTokenCached, .decodeRate, .prefillRate, .firstAudio] }
        if spec.isTranscription { return [.realtimeSpeed] }
        if spec.isImage { return [.secondsPerStep, .imageTime] }
        return [.firstAudio]
    }
    private var tryPane: Pane? {
        if spec.isTTS { return .audio }
        if spec.isEmbedding || spec.isReranker { return .embed }
        if spec.engine == .videogen { return .video }
        if spec.isAudioGen || spec.isAudioEdit { return .audio }
        if spec.engine == .imagetool { return .images }
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
        if spec.isAddOn { return ["POST /v1/videos\nmodel: \(spec.baseModel ?? "")\nlora: \(spec.id)"] }
        if spec.isVideoGen { return ["POST /v1/videos", "GET /v1/videos/{id}/content"] }
        if spec.isAudioGen { return ["POST /v1/audio/generations"] }
        if spec.engine == .imagetool { return [spec.isDepth ? "POST /v1/images/depth" : "POST /v1/images/upscale"] }
        if spec.isAudioEdit { return [SoundService.editTask(spec) == .separate ? "POST /v1/audio/separate" : "POST /v1/audio/enhance"] }
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
            if spec.isChat || spec.isImage, case .ready = state.modelStates[spec.id] { running.id("running") }
            VStack(alignment: .leading, spacing: 8) {
                Text("API").font(.headline)
                ForEach(api, id: \.self) { Text($0).font(.mono(.callout)).textSelection(.enabled) }
                Text("model: \(spec.id)").font(.mono(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task(id: spec.id) { drafts = spec.isChat ? await state.chat.draftCandidates(for: spec) : [] }
    }

    private var keepLoaded: Binding<Bool> {
        Binding(get: { state.settings.keepWarm.contains(spec.id) },
                set: { on in
                    state.settings.keepWarm.removeAll { $0 == spec.id }
                    if on { state.settings.keepWarm.append(spec.id) }
                })
    }

    private var draft: Binding<String> {
        Binding(get: { state.settings.draftModels[spec.id] ?? "" },
                set: { state.settings.draftModels[spec.id] = $0.isEmpty ? nil : $0 })
    }

    /// How this model is kept and run: residency, speculative decoding, and its prompt cache (every request counts).
    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Running").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep loaded")
                    Text("Loads when Synapse starts and is never unloaded for being idle.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.resident(spec.id) == nil {
                    Button("Load Now") { state.preload([spec.id]) }.buttonStyle(.glass)
                }
                Toggle("Keep loaded", isOn: keepLoaded).toggleStyle(.switch).labelsHidden()
            }
            if spec.isChat {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Draft model")
                        Text(drafts.isEmpty
                             ? "Needs a smaller downloaded model with the same tokenizer, both using only full attention (not Qwen3.5)."
                             : "Proposes tokens this model checks in one pass: faster replies, same output.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !drafts.isEmpty {
                        ChoiceMenu(title: "Draft model", selection: draft,
                                   options: [("", "None")] + drafts.map { ($0.id, $0.displayName) })
                    }
                }
                promptCache
            }
        }
    }

    @ViewBuilder private var promptCache: some View {
        let s = state.cacheStats[spec.id] ?? PromptCacheStats()
        let rows: [(String, String, String)] = {
            guard s.requests > 0 else { return [] }
            var r = [("Hit rate", "\(Int((Double(s.hits) / Double(s.requests) * 100).rounded())) %", "\(s.hits) of \(s.requests) requests reused a prompt")]
            if s.promptTokens > 0 {
                r.append(("Tokens reused", "\(Int((Double(s.cachedTokens) / Double(s.promptTokens) * 100).rounded())) %",
                          "\(s.cachedTokens.formatted()) of \(s.promptTokens.formatted()) prompt tokens came from the cache"))
            }
            return r
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Prompt cache").font(.subheadline.weight(.semibold))
                Text("since launch · API requests included").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Cache") { state.clearPromptCache(spec.id, disk: true) }.buttonStyle(.borderless).font(.callout)
                    .disabled(s.entries == 0 && state.diskCache.entries == 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { row in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(row.0)
                        Text(row.1).font(.mono(.body, weight: .bold)).gridColumnAlignment(.trailing)
                        Text(row.2).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("In memory")
                    Text(byteSize(s.bytes)).font(.mono()).gridColumnAlignment(.trailing)
                    Text("\(s.entries) conversation\(s.entries == 1 ? "" : "s"), up to \(gigabytes(state.settings.promptCacheBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if spec.engine == .mlx {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("On disk")
                        Text(byteSize(state.diskCache.bytes)).font(.mono()).gridColumnAlignment(.trailing)
                        Text(state.settings.diskCacheGB > 0 ? "\(state.diskCache.entries) saved prompt\(state.diskCache.entries == 1 ? "" : "s"), all models" : "saving is off in Settings")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if spec.engine == .mlxvlm, !MLXVLMServer.prefixCache {
                Text("Off for mlx-vlm models on Macs with less than 32 GB: its cache refuses requests when free memory runs short.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if s.requests == 0 {
                Text("No requests yet. Follow-up turns reuse the conversation so far instead of reading it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
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
                    if let r = state.resident(spec.id) { Text("loaded · \(r.memory)").font(.mono(.callout)).foregroundStyle(Color.live) }
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
