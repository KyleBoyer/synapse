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
                                       description: Text("Download an image model in Models"))
            } else {
                form(specs)
            }
        }
        .navigationTitle("Images")
        .task { await state.refreshModels() }
        .onChange(of: specs.map(\.id), initial: true) { _, ids in
            if !ids.contains(modelID) { modelID = ids.first ?? "" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { addReferences(urls) }
        }
    }

    private func form(_ specs: [ModelSpec]) -> some View {
        Form {
            Section {
                Picker("Model", selection: $modelID) { ForEach(specs) { Text($0.displayName).tag($0.id) } }
                TextEditor(text: $prompt).frame(minHeight: 70).font(.body)
                    .accessibilityLabel("Prompt")
                DisclosureGroup("Negative prompt") {
                    TextField("Negative prompt", text: $negative, axis: .vertical)
                }
                Picker("Size", selection: $size) { ForEach(Self.sizes, id: \.self) { Text($0).tag($0) } }
                Toggle("Default steps", isOn: $useDefaultSteps)
                if !useDefaultSteps { Stepper("Steps: \(steps)", value: $steps, in: 1...100) }
                Toggle("Random seed", isOn: $randomSeed)
                if !randomSeed { TextField("Seed", text: $seed) }
                Stepper("Images: \(count)", value: $count, in: 1...4)
            }
            if spec?.canEditImages == true {
                Section("Reference images") {
                    if !references.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(references.indices, id: \.self) { i in
                                    if let img = NSImage(data: references[i]) {
                                        Image(nsImage: img).resizable().scaledToFit().frame(height: 80)
                                            .overlay(alignment: .topTrailing) {
                                                Button("Remove reference", systemImage: "xmark.circle.fill") { references.remove(at: i) }
                                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                            }
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Add Images…", systemImage: "paperclip") { importing = true }
                        Text("or drop images here").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in addReferences(urls); return true }
            }
            Section {
                HStack {
                    if running {
                        Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                    } else {
                        Button("Generate", systemImage: "sparkles") { generate() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spec == nil)
                    }
                    if running { progressView }
                }
                if running, let data = progress?.preview, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 240)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            ForEach(history.reversed()) { g in
                Section {
                    Text(g.prompt).font(.callout).lineLimit(3)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(g.images.indices, id: \.self) { i in tile(g.images[i]) }
                    }
                } header: { Text(g.model) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var progressView: some View {
        if preparing {
            ProgressView().controlSize(.small); Text("Preparing model…").foregroundStyle(.secondary)
        } else if let p = progress, p.totalSteps > 0 {
            ProgressView(value: Double(p.step), total: Double(p.totalSteps))
            Text("Image \(imageIndex + 1)/\(count) · step \(p.step)/\(p.totalSteps)").font(.caption).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func tile(_ data: Data) -> some View {
        VStack {
            if let img = NSImage(data: data) { Image(nsImage: img).resizable().scaledToFit().clipShape(.rect(cornerRadius: 6)) }
            HStack {
                Button("Save…", systemImage: "square.and.arrow.down") { save(data) }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(data, forType: .png)
                }
                if spec?.canEditImages == true {
                    Button("Use as reference", systemImage: "photo.badge.plus") { references.append(data) }
                }
            }.buttonStyle(.borderless).controlSize(.small)
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
        let n = count, text = prompt, images = state.images
        error = nil; running = true; progress = nil; imageIndex = 0
        task = Task {
            preparing = !(await images.isLoaded(spec.id))
            defer { running = false; preparing = false; progress = nil }
            do {
                let out = try await images.generate(model: spec, request: req, count: n) { i, p in
                    Task { @MainActor in preparing = false; imageIndex = i; progress = p }
                }
                history.append(Generation(prompt: text, model: spec.displayName, images: out))
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
