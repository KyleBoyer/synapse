import AppKit
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

/// Video → Transform: every frame of a clip through an image tool (depth, subject mask, ×4 upscale), sound kept.
struct VideoTransformView: View {
    struct Result: Identifiable {
        var id = UUID()
        let name: String
        let operation: VideoOperation
        let model: String?
        /// Nil for a saved result: only the output is kept in history (the source is the user's own file).
        var source: URL?
        let output: URL
        let seconds: Double
    }

    @Environment(AppState.self) private var state
    @State private var input: URL?
    @State private var operation = VideoOperation.depth
    @State private var results: [Result] = []
    @State private var running = false
    @State private var fraction = 0.0
    @State private var started: Date?
    @State private var error: String?

    private var needed: ModelSpec? {
        switch operation {
        case .mask: nil
        case .depth: state.downloadedImageToolSpecs.first(where: \.isDepth) == nil ? Catalog.spec("depth-anything-v2-small") : nil
        case .upscale: state.downloadedImageToolSpecs.contains(where: \.isUpscaler) ? nil : Catalog.spec("real-esrgan-general-x4v3")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            canvas
            ScrollView {
                VStack(spacing: 12) { readout; options }.padding(16).frame(maxWidth: .infinity)
            }
            .frame(width: 320)
            .scrollClipDisabled()
        }
        .safeAreaInset(edge: .bottom) { bar.padding([.horizontal, .bottom], 16) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            input = u; return true
        }
        .onChange(of: running) { state.setActive(.video, running) }
        #if DEBUG
        // `-autoVideoTransform <path>` with `-videoOperation depth|mask|upscale` runs once, for captures.
        .task {
            guard let path = UserDefaults.standard.string(forKey: "autoVideoTransform"), results.isEmpty else { return }
            if let op = UserDefaults.standard.string(forKey: "videoOperation").flatMap(VideoOperation.init(rawValue:)) { operation = op }
            input = URL(fileURLWithPath: path); run()
        }
        #endif
        .task(id: state.historyRevision) { await loadHistory() }
        .onChange(of: state.handoff, initial: true) {
            guard case .transformVideo(let url) = state.handoff else { return }
            state.handoff = nil
            input = url
        }
    }

    private var readout: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let last = results.first
            BurnIn(
                name: "Video transform", modelID: last?.model ?? operation.rawValue,
                readings: [
                    Reading(label: "Progress", value: running ? String(format: "%.0f%%", fraction * 100) : "–", live: running),
                    Reading(label: "Elapsed", value: running ? started.map { String(format: "%.1f s", ctx.date.timeIntervalSince($0)) } ?? "–"
                                : last.map { String(format: "%.1f s", $0.seconds) } ?? "–", live: running),
                    Reading(label: "Runs on", value: operation == .upscale ? "MLX" : operation == .depth ? "Core ML" : "Vision"),
                ],
                running: running,
                api: "POST /v1/videos/transform\noperation: \(operation.rawValue)")
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every frame").font(.headline)
            Picker("Operation", selection: $operation) {
                Text("Depth").tag(VideoOperation.depth)
                Text("Mask").tag(VideoOperation.mask)
                Text("Upscale ×4").tag(VideoOperation.upscale)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            if let needed {
                Text("Needs \(needed.displayName). Download it in Models.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Up to \(Int(60)) seconds. Upscaled video is limited to \(ImageService.maxUpscaledVideoSide) px, so the source can be up to \(ImageService.maxUpscaledVideoSide / 4) px.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(running)
        .padding(14)
        .frame(width: 288, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var canvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if results.isEmpty && !running {
                    Text("Choose or drop a video, pick what to do to every frame, and press Transform.")
                        .font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                }
                if running { LiveProgress(label: "Transforming frames", fraction: fraction) }
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.name).font(.title3).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(r.operation.rawValue)\(r.model.map { " · \($0)" } ?? "") · \(String(format: "%.1f s", r.seconds))")
                                .font(.mono(.caption)).foregroundStyle(.secondary)
                            SendToMenu(item: .video(r.output))
                            Button("Transform Again", systemImage: "arrow.trianglehead.2.clockwise") { input = r.output }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Transform again: use this result as the input")
                            Button("Save…", systemImage: "square.and.arrow.down") { save(r.output) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            DeleteItemMenu(noun: "transformed video") {
                                results.removeAll { $0.id == r.id }; state.deleteHistory([r.id], kind: .videoTransform)
                            }
                        }
                        HStack(spacing: 12) {
                            if let source = r.source { ClipPlayer(url: source).aspectRatio(16 / 10, contentMode: .fit).clipShape(.rect(cornerRadius: 14)) }
                            ClipPlayer(url: r.output).aspectRatio(16 / 10, contentMode: .fit).clipShape(.rect(cornerRadius: 14))
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Button(input == nil ? "Choose Video…" : "Change…", systemImage: "film") { choose() }.buttonStyle(.glass)
            if let input { Text(input.lastPathComponent).lineLimit(1).truncationMode(.middle).font(.title3) }
            Spacer(minLength: 0)
            Button("Transform", systemImage: "wand.and.sparkles", action: run)
                .buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                .disabled(input == nil || running || needed != nil)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        if p.runModal() == .OK, let url = p.url { input = url }
    }

    private func run() {
        guard let input, !running else { return }
        let images = state.images, op = operation
        let out = FileManager.default.temporaryDirectory.appending(path: "Synapse-video-\(UUID().uuidString.prefix(8))-\(op.rawValue).mp4")
        running = true; error = nil; fraction = 0; started = Date()
        Task {
            defer { running = false }
            do {
                let spec = try await images.transformVideo(input, to: out, operation: op, model: nil) { f in
                    Task { @MainActor in fraction = f }
                }
                let r = Result(name: input.lastPathComponent, operation: op, model: spec?.id, source: input, output: out,
                               seconds: Date().timeIntervalSince(started ?? Date()))
                results.insert(r, at: 0)
                state.saveHistory(HistoryItem(id: r.id, kind: .videoTransform, title: r.name, model: spec?.id ?? op.rawValue,
                                              payload: (try? JSONEncoder().encode(Saved(operation: op.rawValue, seconds: r.seconds))) ?? Data()),
                                  copy: ["output.mp4": out])
            } catch { self.error = error.localizedDescription }
        }
    }

    private struct Saved: Codable { var operation: String; var seconds: Double }

    private func loadHistory() async {
        guard state.savesHistory else { return }
        var loaded: [Result] = []
        for item in await state.history.list(.videoTransform) {
            guard let s = item.decode(Saved.self), let op = VideoOperation(rawValue: s.operation) else { continue }
            loaded.append(Result(id: item.id, name: item.title, operation: op, model: item.model == s.operation ? nil : item.model,
                                 source: nil, output: await state.history.url(item, "output.mp4"), seconds: s.seconds))
        }
        // This session's results keep their source; earlier ones show the output only.
        let fresh = Dictionary(uniqueKeysWithValues: results.compactMap { r in r.source.map { (r.id, $0) } })
        results = loaded.map { var r = $0; r.source = fresh[r.id]; return r }
    }

    private func save(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.lastPathComponent
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
            } catch { self.error = error.localizedDescription }
        }
    }
}
