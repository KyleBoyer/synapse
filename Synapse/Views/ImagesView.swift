import AppKit
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

struct ImagesView: View {
    @Environment(AppState.self) private var state
    struct Generation: Identifiable {
        let id = UUID()
        let prompt: String
        let model: String
        let images: [Data]
        let seconds: Double
    }
    /// Timing of the generation in flight, measured from the first denoising step (model load excluded).
    struct Timing {
        var firstStep: Date?
        var lastStep: Date?
        var steps = 0
        var secondsPerStep: Double? {
            guard let a = firstStep, let b = lastStep, steps > 1 else { return nil }
            return b.timeIntervalSince(a) / Double(steps - 1)
        }
    }
    private static let sizes = ["1024x1024", "1024x768", "768x1024", "1536x1024", "1024x1536", "512x512"]

    @State private var modelID = ""
    @State private var prompt = ""
    @State private var negative = ""
    @State private var size = "1024x1024"
    @State private var useDefaultSteps = true
    @State private var steps = 20
    @State private var randomSeed = true
    @State private var seed = "0"
    @State private var count = 1
    @State private var references: [Data] = []
    @State private var running = false
    @State private var preparing = false
    @State private var progress: ImageProgress?
    @State private var imageIndex = 0
    @State private var timing = Timing()
    @State private var started: Date?
    @State private var error: String?
    @State private var history: [Generation] = []
    @State private var task: Task<Void, Never>?
    @State private var importing = false

    private var spec: ModelSpec? { Catalog.spec(modelID) }

    var body: some View {
        let specs = state.downloadedImageSpecs
        Group {
            if specs.isEmpty {
                ContentUnavailableView("No image models", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Download FLUX.2 klein, Z-Image Turbo or Qwen-Image in Models."))
            } else {
                HStack(alignment: .top, spacing: 0) {
                    canvas
                    if let spec {
                        ScrollView {
                            VStack(spacing: 12) { readout(spec); settingsPanel }.padding(16).frame(maxWidth: .infinity)
                        }
                        .frame(width: 320)
                        .scrollClipDisabled()
                        
                    }
                }
                .safeAreaInset(edge: .bottom) { promptBar.padding([.horizontal, .bottom], 16) }
            }
        }
        .onChange(of: state.tryRequest, initial: true) { if let s = state.takeTry(.images) { modelID = s.id } }
        .navigationTitle("Images")
        .toolbar {
            ToolbarItemGroup {
                if !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: $modelID, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                        .id(modelID)   // the toolbar measures the menu once; a new identity re-measures it for the chosen name
                }
            }
        }
        .task { await state.refreshModels() }
        .onChange(of: specs.map(\.id), initial: true) { _, ids in
            if !ids.contains(modelID) { modelID = ids.first ?? "" }
        }
        .onChange(of: running) { state.setActive(.images, running) }
        #if DEBUG
        // `-autoImagePrompt "..."` (with `-imageModel <id>`) generates once after launch, for captures.
        .task(id: modelID) {
            guard let p = UserDefaults.standard.string(forKey: "autoImagePrompt"), !p.isEmpty, history.isEmpty, !running, !modelID.isEmpty else { return }
            if let m = UserDefaults.standard.string(forKey: "imageModel"), m != modelID, specs.contains(where: { $0.id == m }) { modelID = m; return }
            prompt = p; generate()
        }
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { addReferences(urls) }
        }
    }

    private func readout(_ spec: ModelSpec) -> some View {
        let p = progress
        let last = history.last
        return BurnIn(
            name: spec.displayName, modelID: spec.id,
            readings: [
                Reading(label: "Step", value: preparing ? "loading model" : p.map { "\($0.step) / \($0.totalSteps)" } ?? "–", live: running),
                timing.secondsPerStep.map { Reading(label: "Per step", value: String(format: "%.2f s", $0), live: running) }
                    ?? Reading(label: "Per step", value: state.metrics.typical(spec.id, .secondsPerStep) ?? "–", muted: true),
                Reading(label: "Image", value: running ? "\(imageIndex + 1) / \(count)" : "–"),
                Reading(label: "Elapsed", value: started.map { String(format: "%.1f s", Date().timeIntervalSince($0)) } ?? "–", live: running),
                last.map { Reading(label: "Last run", value: String(format: "%.1f s", $0.seconds)) }
                    ?? Reading(label: "Image time", value: state.metrics.typical(spec.id, .imageTime) ?? "–", muted: true),
                Reading(label: "Resident", value: state.resident(spec.id).map { gigabytes($0.bytes) } ?? "not loaded"),
            ],
            history: state.metrics.history(spec.id, .secondsPerStep), historyMetric: .secondsPerStep,
            running: running,
            api: "POST /v1/images/generations\nmodel: \(spec.id)")
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow("Size") {
                Picker("Size", selection: $size) { ForEach(Self.sizes, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
            PanelRow("Images") {
                Picker("Images", selection: $count) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            PanelRow("Model's default steps") { Toggle("Model's default steps", isOn: $useDefaultSteps).toggleStyle(.switch).labelsHidden() }
            if !useDefaultSteps {
                PanelRow("Steps") {
                    HStack {
                        Slider(value: Binding(get: { Double(steps) }, set: { steps = Int($0) }), in: 1...50, step: 1).frame(width: 100)
                        Text("\(steps)").font(.mono()).frame(width: 26, alignment: .trailing)
                    }
                }
            }
            PanelRow("Random seed") { Toggle("Random seed", isOn: $randomSeed).toggleStyle(.switch).labelsHidden() }
            if !randomSeed {
                PanelRow("Seed") { TextField("Seed", text: $seed).font(.mono()).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 120) }
            }
            TextField("Negative prompt", text: $negative, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
        }
        .disabled(running)
        .padding(14)
        .frame(width: 288, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder private var canvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if running {
                    ZStack {
                        if let data = progress?.preview, let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: 14).fill(.quaternary).aspectRatio(aspect, contentMode: .fit)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        Group {
                            if preparing {
                                LiveProgress(label: "Loading model")
                            } else if let p = progress, p.totalSteps > 0 {
                                LiveProgress(label: "Step \(p.step) / \(p.totalSteps)", fraction: Double(p.step) / Double(p.totalSteps))
                            } else {
                                LiveProgress(label: "Starting")
                            }
                        }
                        .padding(12).frame(width: 300, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12)).padding(12)
                    }
                    .frame(maxHeight: 520).clipShape(.rect(cornerRadius: 14))
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if history.isEmpty && !running {
                    Text("Describe an image below and press ⌘↩.").font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(history.reversed()) { g in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(g.prompt).font(.title3).lineLimit(2)
                            Spacer()
                            Text("\(g.model) · \(String(format: "%.1f s", g.seconds))").font(.mono(.caption)).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                            ForEach(g.images.indices, id: \.self) { i in tile(g.images[i]) }
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aspect: CGFloat {
        let (w, h) = (try? ImageService.parseSize(size)) ?? (1, 1)
        return CGFloat(w) / CGFloat(max(h, 1))
    }

    private var promptBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if spec?.canEditImages == true, !references.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(references.indices, id: \.self) { i in
                            if let img = NSImage(data: references[i]) {
                                Image(nsImage: img).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 8))
                                    .overlay(alignment: .topTrailing) {
                                        Button("Remove reference", systemImage: "xmark.circle.fill") { references.remove(at: i) }
                                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                if spec?.canEditImages == true {
                    Button("Add reference images", systemImage: "photo.badge.plus") { importing = true }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Add reference images")
                }
                TextField("Describe the image", text: $prompt, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).font(.title3)
                if running {
                    Button("Stop", systemImage: "stop.fill") { task?.cancel() }.buttonStyle(.glass)
                } else {
                    Button("Generate", systemImage: "sparkles") { generate() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spec == nil)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
        .dropDestination(for: URL.self) { urls, _ in
            guard spec?.canEditImages == true else { return false }
            addReferences(urls); return true
        }
    }

    private func tile(_ data: Data) -> some View {
        Group {
            if let img = NSImage(data: data) { Image(nsImage: img).resizable().scaledToFit().clipShape(.rect(cornerRadius: 12)) }
        }
        .contextMenu {
            Button("Save…") { save(data) }
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png) }
            if spec?.canEditImages == true { Button("Use as Reference") { references.append(data) } }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Button("Save…", systemImage: "square.and.arrow.down") { save(data) }
                Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png) }
            }
            .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small).padding(8)
        }
    }

    private func addReferences(_ urls: [URL]) {
        for u in urls { if let d = try? Data(contentsOf: u), NSImage(data: d) != nil { references.append(d) } }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "image.png"
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url) } catch { self.error = error.localizedDescription }
        }
    }

    private func generate() {
        guard let spec else { return }
        let (w, h) = (try? ImageService.parseSize(size)) ?? (1024, 1024)
        let req = ImageRequest(
            prompt: prompt, negativePrompt: negative.isEmpty ? nil : negative, width: w, height: h,
            steps: useDefaultSteps ? nil : steps, seed: randomSeed ? nil : UInt64(seed),
            inputImages: spec.canEditImages ? references : [])
        let n = count, text = prompt, images = state.images, metrics = state.metrics
        error = nil; running = true; progress = nil; imageIndex = 0; timing = Timing(); started = Date()
        task = Task {
            preparing = !(await images.isLoaded(spec.id))
            defer { running = false; preparing = false; progress = nil }
            do {
                let out = try await images.generate(model: spec, request: req, count: n) { i, p in
                    Task { @MainActor in
                        preparing = false
                        if i != imageIndex { timing = Timing() }
                        imageIndex = i; progress = p
                        let now = Date()
                        if timing.firstStep == nil { timing.firstStep = now }
                        timing.lastStep = now; timing.steps += 1
                    }
                }
                let total = Date().timeIntervalSince(started ?? Date())
                timing.secondsPerStep.map { metrics.record(spec.id, .secondsPerStep, $0) }
                if let sps = timing.secondsPerStep {
                    metrics.record(spec.id, .imageTime, sps * Double(progress?.totalSteps ?? timing.steps))
                }
                history.append(Generation(prompt: text, model: spec.id, images: out, seconds: total))
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
