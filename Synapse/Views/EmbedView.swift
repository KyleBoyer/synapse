import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

@MainActor @Observable
final class EmbedModel {
    /// A document: a line of text or an image.
    struct Doc: Identifiable {
        let id: Int
        var text: String?
        var image: Data?
        var input: EmbeddingInput { EmbeddingInput(text: text, image: image) }
    }

    struct Row: Identifiable {
        let id: Int
        let doc: Doc
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
    /// The embedding model of the shown results.
    private(set) var modelID: String?
    /// Why the reranker did not run although one is downloaded (it reads text only).
    private(set) var rerankSkipped: String?

    /// Nil when the model reports no token count (the image models), so no rate is shown or recorded.
    var tokensPerSecond: Double? { tokens > 0 ? seconds.map { $0 > 0 ? Double(tokens) / $0 : 0 } : nil }

    func compare(query: EmbeddingInput, documents: [Doc], spec: ModelSpec, reranker: ModelSpec?, state: AppState) {
        let service = state.embeddings, metrics = state.metrics
        running = true; error = nil
        Task {
            defer { running = false }
            do {
                let warm = await service.isLoaded(spec.id)
                let start = Date()
                let r = try await service.embed(model: spec, inputs: [query] + documents.map(\.input))
                seconds = Date().timeIntervalSince(start)
                cold = !warm
                tokens = r.promptTokens
                dimensions = r.vectors.first?.count
                if warm, let rate = tokensPerSecond { metrics.record(spec.id, .embedRate, rate) }
                var out = documents.enumerated().map { i, d in
                    Row(id: i, doc: d, cosine: EmbeddingService.cosine(r.vectors[0], r.vectors[i + 1]))
                }
                let textOnly = query.image == nil && documents.allSatisfy { $0.image == nil }
                rerankModel = textOnly ? reranker?.id : nil
                rerankSkipped = !textOnly && reranker != nil ? "Reranker skipped: it reads text only" : nil
                if let reranker, textOnly, let q = query.text {
                    for s in try await service.rerank(model: reranker, query: q, documents: documents.compactMap(\.text)) { out[s.index].rerank = s.score }
                    out.sort { ($0.rerank ?? 0) > ($1.rerank ?? 0) }
                } else {
                    out.sort { $0.cosine > $1.cosine }
                }
                rows = out
                modelID = spec.id
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
    @State private var images: [Data] = []
    @State private var queryImage: Data?

    private var spec: ModelSpec? { Catalog.spec(modelID) }
    private var reranker: ModelSpec? { state.downloadedRerankerSpecs.first }
    private var docLines: [String] {
        documents.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var takesImages: Bool { spec.map(EmbeddingService.takesImages) ?? false }
    /// Text lines, then images when the model reads them.
    private var docs: [EmbedModel.Doc] {
        let text = docLines.map { EmbedModel.Doc(id: 0, text: $0) }
        let pics = takesImages ? images.map { EmbedModel.Doc(id: 0, image: $0) } : []
        return (text + pics).enumerated().map { i, d in var d = d; return EmbedModel.Doc(id: i, text: d.text, image: d.image) }
    }
    private var queryInput: EmbeddingInput? {
        let t = query.trimmingCharacters(in: .whitespaces)
        let img = takesImages ? queryImage : nil
        return t.isEmpty && img == nil ? nil : EmbeddingInput(text: t.isEmpty ? nil : t, image: img)
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
            if let wanted = UserDefaults.standard.string(forKey: "tryModel"), wanted != spec.id { return }   // until -tryModel lands
            query = q
            // `-autoCompareImages a.jpg,b.png` adds image documents first (image models only).
            if let paths = UserDefaults.standard.string(forKey: "autoCompareImages") {
                images = paths.split(separator: ",").compactMap { try? Data(contentsOf: URL(fileURLWithPath: String($0))) }
            }
            if let q = queryInput { model.compare(query: q, documents: docs, spec: spec, reranker: reranker, state: state) }
        }
        #endif
    }

    private func readout(_ spec: ModelSpec) -> some View {
        let m = model
        return BurnIn(
            name: spec.displayName, modelID: spec.id,
            readings: [
                Reading(label: "Dimensions", value: m.dimensions.map(String.init) ?? "–"),
                Reading(label: "Tokens", value: m.seconds == nil ? "–" : m.tokens > 0 ? "\(m.tokens)" : "not reported"),
                m.tokensPerSecond.map {
                    Reading(label: m.cold ? "Rate (incl. load)" : "Rate", value: Metric.embedRate.format($0) + " tok/s", live: m.running)
                } ?? Reading(label: "Rate", value: state.metrics.typical(spec.id, .embedRate) ?? "–", muted: true),
                Reading(label: "Time", value: m.seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "–"),
                Reading(label: "Reranker", value: reranker?.id ?? "none downloaded"),
                Reading(label: "Resident", value: state.resident(spec.id).map { $0.memory } ?? "not loaded"),
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
                if takesImages { imageDocs }
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
            HStack(alignment: .firstTextBaseline) {
                Text(hasRerank ? "Ranked by \(model.rerankModel ?? "reranker")" : "Ranked by cosine similarity").font(.headline)
                if let why = model.rerankSkipped { Text(why).font(.callout).foregroundStyle(.secondary) }
            }
            // SigLIP's text-to-text similarities sit far above its text-to-image ones (the two towers are aligned with
            // a sigmoid scale), so images sink in a mixed list even when they match; Qwen3-VL has no such gap.
            if model.modelID == "siglip2-so400m", model.rows.contains(where: { $0.doc.image != nil }), model.rows.contains(where: { $0.doc.text != nil }) {
                Text("SigLIP2 scores text and images on different scales: compare images with images, or use Qwen3-VL Embedding to rank both together.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
                    GridRow(alignment: row.doc.image == nil ? .firstTextBaseline : .center) {
                        Text("\(rank + 1)").font(.mono()).foregroundStyle(.secondary)
                        Text(String(format: "%.3f", row.cosine)).font(.mono())
                        if hasRerank { Text(row.rerank.map { String(format: "%.3f", $0) } ?? "–").font(.mono(.body, weight: .bold)) }
                        if let data = row.doc.image, let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 64)
                                .clipShape(.rect(cornerRadius: 6)).accessibilityLabel("Image document")
                        } else {
                            Text(row.doc.text ?? "").textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 8)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    /// The query stays in the field: comparisons are usually refined, not replaced.
    private func compare() {
        guard let spec, !model.running, let q = queryInput, !docs.isEmpty else { return }
        model.compare(query: q, documents: docs, spec: spec, reranker: reranker, state: state)
    }

    /// Image documents, for models that embed images.
    private var imageDocs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Images").font(.headline)
                Spacer()
                Button("Add Images…", systemImage: "photo.badge.plus") { pickImages { images += $0 } }.buttonStyle(.glass)
            }
            if images.isEmpty {
                Text("Add or drop images to rank them against the query with the text above.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, data in
                            ZStack(alignment: .topTrailing) {
                                if let img = NSImage(data: data) {
                                    Image(nsImage: img).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(.rect(cornerRadius: 8))
                                }
                                Button("Remove image", systemImage: "xmark.circle.fill") { images.remove(at: i) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            let pics = items.filter { NSImage(data: $0) != nil }
            images += pics
            return !pics.isEmpty
        }
    }

    private func pickImages(_ done: ([Data]) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { done(p.urls.compactMap { try? Data(contentsOf: $0) }) }
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if takesImages {
                if let data = queryImage, let img = NSImage(data: data) {
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(.rect(cornerRadius: 6))
                        Button("Remove query image", systemImage: "xmark.circle.fill") { queryImage = nil }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                } else {
                    Button("Query with an image", systemImage: "photo") { pickImages { queryImage = $0.first } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Query with an image")
                }
            }
            TextField(takesImages ? "Query (text, an image, or both)" : "Query", text: $query, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.plain).font(.title3)
                .onSubmit(compare).composerKeys()
            Button("Compare", systemImage: "arrow.up.arrow.down", action: compare)
            .buttonStyle(.glassProminent)
            .disabled(model.running || queryInput == nil || docs.isEmpty || spec == nil)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
    }
}
