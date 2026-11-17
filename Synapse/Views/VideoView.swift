import AVKit
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

struct VideoView: View {
    @Environment(AppState.self) private var state
    private static let sizes = ["768x512", "512x768", "1280x704", "704x1280"]
    #if DEBUG
    @MainActor private static var autoQueued = false
    #endif

    @State private var modelID = ""
    @State private var prompt = ""
    @State private var seconds = 4
    @State private var size = "768x512"
    @State private var randomSeed = true
    @State private var seed = "0"
    @State private var startImage: Data?
    @State private var importing = false
    /// Newest first, as the service reports them.
    @State private var jobs: [VideoJob] = []
    @State private var error: String?

    private var specs: [ModelSpec] {
        VideoEngines.mock ? Catalog.all.filter(\.isVideoGen) : state.downloadedVideoSpecs
    }
    private var spec: ModelSpec? { Catalog.spec(modelID) }
    private var active: VideoJob? { jobs.first { $0.status == .in_progress } ?? jobs.first { $0.status == .queued } }
    private var running: Bool { active != nil }

    var body: some View {
        Group {
            if specs.isEmpty {
                ContentUnavailableView("No video models", systemImage: "film",
                                       description: Text("Download LTX-2.3 Distilled in Models. It needs about 96 GB of memory and disk."))
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
        .navigationTitle("Video")
        .toolbar {
            ToolbarItemGroup {
                if !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: $modelID, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                }
            }
        }
        .task { await state.refreshModels() }
        .task {
            // Generation lives in the service, so leaving the pane keeps it running; coming back resumes the list.
            jobs = await state.videos.all()
            for await j in await state.videos.updates() {
                if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.insert(j, at: 0) }
                if j.status == .completed, !VideoEngines.mock, let start = j.startedAt, let end = j.completedAt {
                    state.metrics.record(j.model, .videoTime, end.timeIntervalSince(start))
                }
            }
        }
        .onChange(of: specs.map(\.id), initial: true) { _, ids in
            if !ids.contains(modelID) { modelID = ids.first ?? "" }
        }
        .onChange(of: running) { state.setActive(.video, running) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { r in
            if case .success(let url) = r { startImage = try? Data(contentsOf: url) }
        }
        #if DEBUG
        // `-autoVideoPrompt "..."` queues one clip after launch, so a run can be captured without typing.
        .task(id: spec?.id) {
            guard let p = UserDefaults.standard.string(forKey: "autoVideoPrompt"), !p.isEmpty, !Self.autoQueued, spec != nil else { return }
            Self.autoQueued = true
            prompt = p; generate()
        }
        #endif
    }

    private func readout(_ spec: ModelSpec) -> some View {
        let a = active
        let last = jobs.first { $0.status == .completed }
        return BurnIn(
            name: spec.displayName, modelID: spec.id,
            readings: [
                Reading(label: "Status", value: a.map { $0.status == .queued ? "queued" : "generating" } ?? "idle", live: running),
                Reading(label: "Progress", value: a.map { "\($0.progress)%" } ?? "–", live: running),
                Reading(label: "Elapsed", value: a?.startedAt.map { String(format: "%.1f s", Date().timeIntervalSince($0)) } ?? "–", live: running),
                last.flatMap { j in j.startedAt.flatMap { s in j.completedAt.map { String(format: "%.1f s", $0.timeIntervalSince(s)) } } }
                    .map { Reading(label: "Last clip", value: $0) }
                    ?? Reading(label: "Clip time", value: state.metrics.typical(spec.id, .videoTime) ?? "–", muted: true),
                Reading(label: "Queued", value: "\(jobs.filter { $0.status == .queued }.count)"),
                Reading(label: "Memory", value: spec.recommendedRAMGB.map { "\($0) GB needed" } ?? "–"),
            ],
            history: state.metrics.history(spec.id, .videoTime), historyMetric: .videoTime,
            running: running,
            api: "POST /v1/videos\nmodel: \(spec.id)")
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow("Length") {
                Picker("Length", selection: $seconds) { ForEach([4, 8, 12], id: \.self) { Text("\($0) s").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            PanelRow("Size") {
                Picker("Size", selection: $size) { ForEach(Self.sizes, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
            PanelRow("Random seed") { Toggle("Random seed", isOn: $randomSeed).toggleStyle(.switch).labelsHidden() }
            if !randomSeed {
                PanelRow("Seed") {
                    TextField("Seed", text: $seed).font(.mono()).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 120)
                }
            }
            PanelRow("Start image") {
                HStack(spacing: 6) {
                    if let d = startImage, let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 6))
                        Button("Remove start image", systemImage: "xmark.circle.fill") { startImage = nil }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    } else {
                        Button("Choose…") { importing = true }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 288, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder private var canvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if jobs.isEmpty {
                    Text("Describe a clip below and press ⌘↩.").font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(jobs) { job in clip(job) }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func clip(_ j: VideoJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(j.prompt).font(.title3).lineLimit(2)
                Spacer()
                Text(meta(j)).font(.mono(.caption)).foregroundStyle(.secondary)
            }
            Group {
                switch j.status {
                case .completed:
                    if let file = j.file { ClipPlayer(url: file) }
                case .failed:
                    Label(j.error ?? "Generation failed.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .queued, .in_progress:
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                        Text(j.status == .queued ? "Queued" : "\(j.progress)%")
                            .font(.mono(.title3)).foregroundStyle(Color.live)
                    }
                }
            }
            .aspectRatio(CGFloat(j.request.width) / CGFloat(max(j.request.height, 1)), contentMode: .fit)
            .frame(maxHeight: 460)
            .clipShape(.rect(cornerRadius: 14))
            .contextMenu {
                if let file = j.file { Button("Save…") { save(file) } }
                Button("Delete", role: .destructive) { Task { _ = await state.videos.delete(j.id); jobs.removeAll { $0.id == j.id } } }
            }
            .overlay(alignment: .topTrailing) {
                if let file = j.file {
                    Button("Save…", systemImage: "square.and.arrow.down") { save(file) }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small).padding(8)
                } else if !j.status.isDone {
                    Button("Stop", systemImage: "stop.fill") { Task { _ = await state.videos.delete(j.id); jobs.removeAll { $0.id == j.id } } }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small).padding(8)
                }
            }
        }
    }

    private func meta(_ j: VideoJob) -> String {
        var parts = [j.model, "\(j.seconds) s", "\(j.request.width)x\(j.request.height)"]
        if let s = j.startedAt, let e = j.completedAt, j.status == .completed { parts.append(String(format: "%.1f s", e.timeIntervalSince(s))) }
        return parts.joined(separator: " · ")
    }

    private var promptBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Describe the clip", text: $prompt, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).font(.title3)
            Button("Generate", systemImage: "film") { generate() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spec == nil)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
    }

    private func save(_ file: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "clip.mp4"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: file, to: url)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Queues a clip; several can wait in line, the service runs one at a time.
    private func generate() {
        guard let spec else { return }
        let dims = size.split(separator: "x").compactMap { Int($0) }
        let req = VideoRequest(prompt: prompt, width: dims[0], height: dims[1], frames: VideoService.frames(seconds: seconds),
                               seed: randomSeed ? nil : UInt64(seed), inputImage: startImage)
        error = nil
        Task { _ = await state.videos.create(model: spec, request: req) }
    }
}

private extension VideoJob.Status {
    var isDone: Bool { self == .completed || self == .failed }
}

/// One clip with AppKit's player controls. SwiftUI's VideoPlayer is avoided: its AVKit overlay aborted at launch
/// (fatal error in _AVKit_SwiftUI class metadata) on macOS 26.
private struct ClipPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url { view.player = AVPlayer(url: url) }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }
}
