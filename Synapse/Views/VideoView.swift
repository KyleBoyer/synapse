import AVKit
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

struct VideoView: View {
    #if DEBUG
    @MainActor static var autoNextDone = false
    #endif
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
    @FocusState private var promptFocused: Bool
    @State private var importing = false
    /// Newest first, as the service reports them.
    @State private var jobs: [VideoJob] = []
    /// Clips from earlier sessions (and this one's, once their job is gone from the service).
    @State private var saved: [(item: HistoryItem, saved: Saved, url: URL)] = []
    struct Saved: Codable { var job: String; var meta: String }
    @State private var error: String?

    private var specs: [ModelSpec] {
        VideoEngines.mock ? Catalog.all.filter(\.isVideoGen) : state.downloadedVideoSpecs
    }
    private var spec: ModelSpec? { Catalog.spec(modelID) }
    private var active: VideoJob? { jobs.first { $0.status == .in_progress } ?? jobs.first { $0.status == .queued } }
    private var running: Bool { active != nil }

    enum Mode: String, CaseIterable { case generate = "Generate", transform = "Transform" }
    @State private var mode = Mode.generate

    var body: some View {
        Group {
            if mode == .transform {
                VideoTransformView()
            } else if specs.isEmpty, saved.isEmpty {
                ContentUnavailableView("No video models", systemImage: "film",
                                       description: Text("Download LTX-2.3 Distilled in Models. On Macs under 64 GB it runs in low-memory mode (about 55 GB download)."))
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
        .onChange(of: state.tryRequest, initial: true) { if let s = state.takeTry(.video) { modelID = s.id } }
        .navigationTitle("Video")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().disabled(running)
            }
            ToolbarItemGroup {
                if mode == .generate, !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: $modelID, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                        .id(modelID)   // the toolbar measures the menu once; a new identity re-measures it for the chosen name
                }
                ClearHistoryButton(noun: mode == .generate ? "clip" : "transformed video") {
                    state.clearHistory(mode == .generate ? .video : .videoTransform)
                }
            }
        }
        .task(id: state.historyRevision) {
            guard state.savesHistory else { return }
            var loaded: [(item: HistoryItem, saved: Saved, url: URL)] = []
            for item in await state.history.list(.video) {
                if let s = item.decode(Saved.self) { loaded.append((item, s, await state.history.url(item, "clip.mp4"))) }
            }
            saved = loaded
        }
        .task {
            await state.refreshModels()
            #if DEBUG
            if UserDefaults.standard.string(forKey: "autoVideoTransform") != nil { mode = .transform }
            #endif
        }
        .task {
            // Generation lives in the service, so leaving the pane keeps it running; coming back resumes the list.
            jobs = await state.videos.all()
            for await j in await state.videos.updates() {
                if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.insert(j, at: 0) }
                if j.status == .completed, !VideoEngines.mock, let start = j.startedAt, let end = j.completedAt {
                    state.metrics.record(j.model, .videoTime, end.timeIntervalSince(start))
                }
                if j.status == .completed, let file = j.file, state.guiVideoJobs.remove(j.id) != nil {
                    state.saveHistory(HistoryItem(kind: .video, title: j.prompt, model: j.model,
                                                  payload: (try? JSONEncoder().encode(Saved(job: j.id, meta: meta(j)))) ?? Data()),
                                      copy: ["clip.mp4": file])
                }
            }
        }
        .onChange(of: specs.map(\.id), initial: true) { _, ids in
            if !ids.contains(modelID) { modelID = ids.first ?? "" }
        }
        #if DEBUG
        // `-autoNext continue|transform` presses that button on the first finished clip (saved or new), for checks.
        .onChange(of: (jobs.first { $0.file != nil }?.file ?? saved.first?.url)?.path) {
            guard let next = UserDefaults.standard.string(forKey: "autoNext"), !Self.autoNextDone,
                  let file = jobs.first(where: { $0.file != nil })?.file ?? saved.first?.url else { return }
            Self.autoNextDone = true
            if next == "continue" { Task { await continueFrom(file) } } else if next == "transform" { state.send(.transformVideo(file)) }
        }
        #endif
        .onChange(of: state.handoff, initial: true) {
            switch state.handoff {
            case .animateImage(let data):
                state.handoff = nil
                mode = .generate; startImage = data; prompt = ""; promptFocused = true
            case .transformVideo:
                mode = .transform   // VideoTransformView takes the clip itself
            case .prompt(let text, .video):
                state.handoff = nil
                mode = .generate; prompt = text; promptFocused = true
            default: break
            }
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
                    Text("Describe a clip below and press Return.").font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(jobs) { job in clip(job) }
                let earlier = saved.filter { s in !jobs.contains { $0.id == s.saved.job } }
                if !earlier.isEmpty {
                    Text("Earlier").font(.headline).padding(.top, 8)
                    ForEach(earlier, id: \.item.id) { s in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(s.item.title).font(.title3).lineLimit(2)
                                Spacer()
                                Text(s.saved.meta).font(.mono(.caption)).foregroundStyle(.secondary)
                                DeleteItemMenu(noun: "clip") { state.deleteHistory([s.item.id], kind: .video) }
                            }
                            ClipPlayer(url: s.url).aspectRatio(16 / 9, contentMode: .fit).frame(maxHeight: 460).clipShape(.rect(cornerRadius: 14))
                                .contextMenu { Button("Save…") { save(s.url) } }
                                .overlay(alignment: .topTrailing) {
                                    HStack(spacing: 4) { nextSteps(s.url) }
                                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small).padding(8)
                                }
                        }
                    }
                }
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
                    RoundedRectangle(cornerRadius: 14).fill(.quaternary).overlay(alignment: .bottom) {
                        // Each clip runs in a fresh process, so progress stays 0 until the model is loaded.
                        if j.status == .queued {
                            LiveProgress(label: "Queued").strip()
                        } else if j.progress == 0 {
                            LiveProgress(label: "Loading model").strip()
                        } else {
                            LiveProgress(label: "Generating · \(j.progress)%", fraction: Double(j.progress) / 100).strip()
                        }
                    }
                }
            }
            .aspectRatio(CGFloat(j.request.width) / CGFloat(max(j.request.height, 1)), contentMode: .fit)
            .frame(maxHeight: 460)
            .clipShape(.rect(cornerRadius: 14))
            .contextMenu {
                if let file = j.file { Button("Save…") { save(file) } }
                Button("Delete", role: .destructive) {
                    Task {
                        _ = await state.videos.delete(j.id); jobs.removeAll { $0.id == j.id }
                        state.deleteHistory(saved.filter { $0.saved.job == j.id }.map(\.item.id), kind: .video)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let file = j.file {
                    HStack(spacing: 4) {
                        nextSteps(file)
                        Button("Save…", systemImage: "square.and.arrow.down") { save(file) }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small).padding(8)
                } else if !j.status.isDone {
                    Button("Stop", systemImage: "stop.fill") { Task { _ = await state.videos.delete(j.id); jobs.removeAll { $0.id == j.id } } }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small).padding(8)
                }
            }
        }
    }

    /// What a finished clip can feed next: a new clip that starts where it ends, or Transform.
    @ViewBuilder private func nextSteps(_ file: URL) -> some View {
        Button("Continue", systemImage: "arrow.forward.to.line") { Task { await continueFrom(file) } }
            .disabled(specs.isEmpty)
            .help("Continue: start a new clip from this clip's last frame")
        Button("Transform", systemImage: "wand.and.sparkles") { state.send(.transformVideo(file)) }
            .help("Transform every frame: depth, subject mask or upscale")
        SendToMenu(item: .video(file))
    }

    private func continueFrom(_ file: URL) async {
        guard let frame = await Self.lastFrame(file) else { error = "Could not read the clip's last frame."; return }
        mode = .generate
        startImage = frame
        prompt = ""
        promptFocused = true
    }

    /// The clip's final frame as PNG, the start image for a clip that continues it.
    static func lastFrame(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // A frame's length before the end: asking for the end itself can return nothing.
        let at = CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))
        guard let (cg, _) = try? await generator.image(at: CMTimeMaximum(at, .zero)) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private func meta(_ j: VideoJob) -> String {
        var parts = [j.model, "\(j.seconds) s", "\(j.request.width)x\(j.request.height)"]
        if let s = j.startedAt, let e = j.completedAt, j.status == .completed { parts.append(String(format: "%.1f s", e.timeIntervalSince(s))) }
        return parts.joined(separator: " · ")
    }

    private var promptBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(startImage == nil ? "Describe the clip" : "Describe what happens from the start image", text: $prompt, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).font(.title3)
                .focused($promptFocused)
                .onSubmit(generate).composerKeys()
            Button("Generate", systemImage: "film") { generate() }
                .buttonStyle(.glassProminent)
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
        guard let spec, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let dims = size.split(separator: "x").compactMap { Int($0) }
        let req = VideoRequest(prompt: prompt, width: dims[0], height: dims[1], frames: VideoService.frames(seconds: seconds),
                               seed: randomSeed ? nil : UInt64(seed), inputImage: startImage)
        error = nil; prompt = ""
        Task { state.guiVideoJobs.insert(await state.videos.create(model: spec, request: req).id) }
    }
}

private extension VideoJob.Status {
    var isDone: Bool { self == .completed || self == .failed }
}

/// One clip with AppKit's player controls. SwiftUI's VideoPlayer is avoided: its AVKit overlay aborted at launch
/// (fatal error in _AVKit_SwiftUI class metadata) on macOS 26.
struct ClipPlayer: NSViewRepresentable {
    let url: URL
    /// Players on screen by file, so Send To can take the frame at the playhead.
    @MainActor private static var players: [URL: AVPlayer] = [:]
    @MainActor static func playhead(_ url: URL) -> CMTime? { players[url]?.currentTime() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        Self.players[url] = view.player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url { view.player = AVPlayer(url: url); Self.players[url] = view.player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        if let url = (view.player?.currentItem?.asset as? AVURLAsset)?.url, players[url] === view.player { players[url] = nil }
    }
}
