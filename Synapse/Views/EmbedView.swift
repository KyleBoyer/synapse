import SwiftUI
import SynapseCore

@MainActor @Observable
final class EmbedModel {
    struct Row: Identifiable {
        let id: Int
        let text: String
        let cosine: Float
        var rerank: Double?
    }

    var rows: [Row] = []
    var running = false
    var error: String?
    private(set) var dimensions: Int?
    private(set) var tokens = 0
    private(set) var seconds: Double?
    /// The run loaded the model, so its time is load plus inference and is not recorded as a measurement.
    private(set) var cold = false
    private(set) var rerankModel: String?

    var tokensPerSecond: Double? { seconds.map { $0 > 0 ? Double(tokens) / $0 : 0 } }

    func compare(query: String, documents: [String], spec: ModelSpec, reranker: ModelSpec?, state: AppState) {
        let service = state.embeddings, metrics = state.metrics
        running = true; error = nil
        Task {
            defer { running = false }
            do {
                let warm = await service.isLoaded(spec.id)
                let start = Date()
                let r = try await service.embed(model: spec, inputs: [query] + documents)
                seconds = Date().timeIntervalSince(start)
                cold = !warm
                tokens = r.promptTokens
                dimensions = r.vectors.first?.count
                if warm, let rate = tokensPerSecond { metrics.record(spec.id, .embedRate, rate) }
                var out = documents.enumerated().map { i, d in
                    Row(id: i, text: d, cosine: EmbeddingService.cosine(r.vectors[0], r.vectors[i + 1]))
                }
                rerankModel = reranker?.id
                if let reranker {
                    for s in try await service.rerank(model: reranker, query: query, documents: documents) { out[s.index].rerank = s.score }
                    out.sort { ($0.rerank ?? 0) > ($1.rerank ?? 0) }
                } else {
                    out.sort { $0.cosine > $1.cosine }
                }
                rows = out
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct EmbedView: View {
    @Environment(AppState.self) private var state
    @State private var modelID = ""
    @State private var query = ""
    @AppStorage("embed.documents") private var documents = """
        Paris is the capital of France.
        The Eiffel Tower was finished in 1889.
        Bananas are rich in potassium.
        Berlin is the capital of Germany.
        """
    @State private var model = EmbedModel()

    private var spec: ModelSpec? { Catalog.spec(modelID) }
    private var reranker: ModelSpec? { state.downloadedRerankerSpecs.first }
    private var docLines: [String] {
        documents.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        let specs = state.downloadedEmbeddingSpecs
        Group {
            if specs.isEmpty {
                ContentUnavailableView("No embedding models", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Download Qwen3 Embedding 0.6B in Models."))
            } else {
                HStack(alignment: .top, spacing: 0) {
                    content
                    if let spec {
                        ScrollView {
                            VStack(spacing: 12) { readout(spec) }.padding(16).frame(maxWidth: .infinity)
                        }
                        .frame(width: 320)
                        .scrollClipDisabled()
                    }
                }
                .safeAreaInset(edge: .bottom) { bar.padding([.horizontal, .bottom], 16) }
            }
        }
        .onChange(of: state.tryRequest, initial: true) { if let s = state.takeTry(.embed) { if s.isEmbedding { modelID = s.id } } }
        .navigationTitle("Embed")
        .toolbar {
            ToolbarItemGroup {
                if !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: $modelID, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                }
            }
        }
        .task { await state.refreshModels() }
        .onChange(of: specs.map(\.id), initial: true) { _, ids in
            if !ids.contains(modelID) { modelID = ids.first ?? "" }
        }
        .onChange(of: model.running) { state.setActive(.embed, model.running) }
        #if DEBUG
        // `-autoCompare "..."` runs one comparison after launch, so the results can be captured without typing.
        .task(id: spec?.id) {
            guard let q = UserDefaults.standard.string(forKey: "autoCompare"), !q.isEmpty, model.rows.isEmpty, let spec else { return }
            query = q
            model.compare(query: q, documents: docLines, spec: spec, reranker: reranker, state: state)
        }
        #endif
    }

    private func readout(_ spec: ModelSpec) -> some View {
        let m = model
        return BurnIn(
            name: spec.displayName, modelID: spec.id,
            readings: [
                Reading(label: "Dimensions", value: m.dimensions.map(String.init) ?? "–"),
                Reading(label: "Tokens", value: m.seconds == nil ? "–" : "\(m.tokens)"),
                m.tokensPerSecond.map {
                    Reading(label: m.cold ? "Rate (incl. load)" : "Rate", value: Metric.embedRate.format($0) + " tok/s", live: m.running)
                } ?? Reading(label: "Rate", value: state.metrics.typical(spec.id, .embedRate) ?? "–", muted: true),
                Reading(label: "Time", value: m.seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "–"),
                Reading(label: "Reranker", value: reranker?.id ?? "none downloaded"),
                Reading(label: "Resident", value: state.resident(spec.id).map { gigabytes($0.bytes) } ?? "not loaded"),
            ],
            history: state.metrics.history(spec.id, .embedRate), historyMetric: .embedRate,
            running: m.running,
            api: "POST /v1/embeddings\nmodel: \(spec.id)")
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Documents, one per line").font(.headline)
                    TextEditor(text: $documents)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 110, maxHeight: 180)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                }
                if !model.rows.isEmpty { results }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var results: some View {
        let hasRerank = model.rows.contains { $0.rerank != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text(hasRerank ? "Ranked by \(model.rerankModel ?? "reranker")" : "Ranked by cosine similarity").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Text("#")
                    Text("Cosine").gridColumnAlignment(.trailing)
                    if hasRerank { Text("Rerank").gridColumnAlignment(.trailing) }
                    Text("Document")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { rank, row in
                    GridRow(alignment: .firstTextBaseline) {
                        Text("\(rank + 1)").font(.mono()).foregroundStyle(.secondary)
                        Text(String(format: "%.3f", row.cosine)).font(.mono())
                        if hasRerank { Text(row.rerank.map { String(format: "%.3f", $0) } ?? "–").font(.mono(.body, weight: .bold)) }
                        Text(row.text).textSelection(.enabled)
                    }
                    .padding(.vertical, 8)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Query", text: $query, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.plain).font(.title3)
            Button("Compare", systemImage: "arrow.up.arrow.down") {
                if let spec { model.compare(query: query, documents: docLines, spec: spec, reranker: reranker, state: state) }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.running || query.trimmingCharacters(in: .whitespaces).isEmpty || docLines.isEmpty || spec == nil)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
    }
}
