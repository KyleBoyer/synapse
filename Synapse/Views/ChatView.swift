import AppKit
import AVFoundation
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppState.self) private var state
    @Environment(\.paneShown) private var paneShown
    /// A conversation line plus when it started, relative to the conversation's first message.
    struct Line { var message: ChatMessage; var at: Double }
    /// The run being measured: what it is doing now, when each phase began, tokens so far, final usage.
    struct Run {
        enum Phase: Equatable { case waiting, loading, prompt(fraction: Double?), generating }
        var sent = Date()
        var phase = Phase.waiting
        var phaseStart = Date()
        var loadSeconds: Double?
        var promptStart: Date?
        var firstToken: Date?
        var chunks = 0
        var ended: Date?
        var usage: ChatUsage?
        var firstTokenSeconds: Double? { firstToken.map { $0.timeIntervalSince(promptStart ?? sent) } }

        mutating func apply(_ p: ChatProgress) {
            switch p {
            case .loadStarted: phase = .loading; phaseStart = Date()
            case .loaded(let s): loadSeconds = s; phase = .waiting
            case .promptStarted: phase = .prompt(fraction: nil); phaseStart = Date(); promptStart = phaseStart
            case .prompt(let f): phase = .prompt(fraction: f)
            case .promptDone: break   // the first delta switches to generating
            }
        }
        var decodeRate: Double? {
            guard let f = firstToken else { return nil }
            let tokens = Double((usage?.completionTokens ?? chunks) - 1)
            let t = (ended ?? Date()).timeIntervalSince(f)
            return t > 0.05 && tokens > 0 ? tokens / t : nil
        }
        /// Only for runs that read the whole prompt: a cached prefix would make it look far faster than the model is.
        var promptRate: Double? {
            guard let u = usage, u.cachedTokens == 0, let ttft = firstTokenSeconds, ttft > 0 else { return nil }
            return Double(u.promptTokens) / ttft
        }
        var cached: Bool { (usage?.cachedTokens ?? 0) > 0 }
    }

    @State private var modelID = ""
    @State private var lines: [Line] = []
    @State private var started: Date?
    @State private var input = ""
    @State private var pending: [Data] = []
    @State private var pendingVideos: [URL] = []
    @State private var pendingAudios: [URL] = []
    @State private var generating = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var run: Run?
    /// The saved conversation this chat is (a new one on New Chat; the opened one from History).
    @State private var conversation = UUID()
    @FocusState private var composerFocused: Bool

    private var specs: [ModelSpec] { state.downloadedChatSpecs }
    private var spec: ModelSpec? { specs.first { $0.id == modelID } }

    var body: some View {
        Group {
            if specs.isEmpty {
                ContentUnavailableView("No chat model", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Download a Qwen3.5 model in Models."))
            } else {
                // The composer spans the whole pane; the readout column sits above it and never overlaps.
                HStack(alignment: .top, spacing: 0) {
                    transcript
                    if let spec { ScrollView { readout(spec).padding(16).frame(maxWidth: .infinity) }.frame(width: 320).scrollClipDisabled() }
                }
                .safeAreaInset(edge: .bottom) { composer.padding([.horizontal, .bottom], 16) }
            }
        }
        .onChange(of: state.tryRequest, initial: true) { if let s = state.takeTry(.chat) { modelID = s.id } }
        .toolbar { if paneShown {
            ToolbarItemGroup {
                if !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: $modelID, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                }
                HistoryButton(kind: .chat, noun: "chat") { open($0) }
                Button("New Chat", systemImage: "square.and.pencil") {
                    stop(); lines = []; started = nil; pending = []; pendingVideos = []; pendingAudios = []; error = nil; run = nil
                    conversation = UUID()
                }
                    .help("New Chat")
            }
        } }
        .task { await state.refreshModels() }
        .onAppear { pickModel(); composerFocused = true }
        #if DEBUG
        // `-autoSendPrompt "..."` sends one message after launch, so streaming states can be captured without typing.
        .task(id: spec?.id) {
            guard let p = UserDefaults.standard.string(forKey: "autoSendPrompt"), !p.isEmpty, lines.isEmpty, spec != nil else { return }
            // `-autoAttach <path>` attaches a file first, so video and image runs can be captured too.
            if let path = UserDefaults.standard.string(forKey: "autoAttach") { add([URL(fileURLWithPath: path)]) }
            // Several prompts separated by " || " are sent one after another, each once the previous reply ends.
            for (i, q) in p.components(separatedBy: " || ").enumerated() {
                if i > 0 { while generating { try? await Task.sleep(for: .milliseconds(200)) } }
                input = q; send()
            }
        }
        #endif
        .onChange(of: specs.map(\.id)) { pickModel() }
        .onChange(of: generating) { state.setActive(.chat, generating) }
        .onChange(of: state.handoff, initial: true) {
            guard case .chat(let text, let images, let videos, let audios) = state.handoff else { return }
            state.handoff = nil
            if !text.isEmpty { input = text }
            pending += images; pendingVideos += videos; pendingAudios += audios
            composerFocused = true
            // Pick a model that can take what arrived: audio needs an omni model (mlx-vlm), video a video-capable one.
            let chat = state.chat, current = spec
            Task {
                if !audios.isEmpty, let current, await !chat.supportsAudio(current),
                   let omni = specs.first(where: { $0.engine == .mlxvlm }) { modelID = omni.id; return }
                if !videos.isEmpty, let current, await !chat.supportsVideo(current) {
                    for s in specs where await chat.supportsVideo(s) { modelID = s.id; return }
                }
            }
        }
    }

    private func pickModel() {
        #if DEBUG
        // `-chatModel <id>` picks the model for captures.
        if modelID.isEmpty, let m = UserDefaults.standard.string(forKey: "chatModel"), specs.contains(where: { $0.id == m }) { modelID = m }
        #endif
        if !specs.contains(where: { $0.id == modelID }) { modelID = specs.first?.id ?? "" }
    }

    private func readout(_ spec: ModelSpec) -> some View {
        let r = run
        let resident = state.resident(spec.id), m = state.metrics
        // This run's value, or the typical from past runs in secondary ink.
        func reading(_ label: String, _ v: String?, _ metric: Metric, live: Bool = false) -> Reading {
            v.map { Reading(label: label, value: $0, live: live) }
                ?? Reading(label: label, value: m.typical(spec.id, metric) ?? "–", muted: true)
        }
        return BurnIn(
            name: spec.displayName, modelID: spec.id,
            readings: [
                reading("Load", r?.loadSeconds.map { String(format: "%.2f s", $0) }
                            ?? (r?.promptStart != nil ? "already loaded" : nil), .loadTime, live: r?.phase == .loading),
                reading("First token", r?.firstTokenSeconds.map { String(format: "%.2f s", $0) }, r?.cached == true ? .firstTokenCached : .firstToken),
                reading("Decode", r?.decodeRate.map { Metric.decodeRate.format($0) + " tok/s" }, .decodeRate, live: generating),
                reading("Prompt", r?.usage.map { u in
                    "\(u.promptTokens) tok" + (u.cachedTokens > 0 ? " · \(u.cachedTokens) cached"
                                                : r?.promptRate.map { " · " + Metric.prefillRate.format($0) + "/s" } ?? "")
                }, .prefillRate),
                Reading(label: "Output", value: r.map { "\($0.usage?.completionTokens ?? $0.chunks) tok" } ?? "–"),
            ] + (r?.usage?.drafted == true ? [Reading(label: "Draft", value: state.settings.draftModels[spec.id] ?? "on")] : [])
              + (lines.last(where: { $0.message.role == .user })?.message.videos.isEmpty == false
                 ? [Reading(label: "Video", value: "\(ChatOptions().videoFrames ?? 8) frames")] : []) + [
                Reading(label: "Resident", value: resident.map { $0.memory } ?? "not loaded"),
            ],
            history: state.metrics.history(spec.id, .decodeRate), historyMetric: .decodeRate,
            running: generating,
            apiFormats: APIFormat.chat(model: spec.id, base: ServerView.endpoint(state.settings),
                                       key: state.settings.allowLAN ? state.settings.apiKey : nil))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if lines.isEmpty {
                        Text("Send a message, or drop an image or video, to try \(spec?.displayName ?? "the model").")
                            .font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                    }
                    ForEach(lines.indices, id: \.self) { i in line(lines[i], current: generating && i == lines.count - 1) }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .onChange(of: lines.last?.message.text) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func line(_ l: Line, current: Bool) -> some View {
        let user = l.message.role == .user
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(timecode(l.at)).font(.mono(.caption)).foregroundStyle(current ? Color.live : Color.secondary)
                .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(user ? "You" : (spec?.displayName ?? "Model")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if !user, !current, !l.message.text.isEmpty { SendToMenu(item: .text(l.message.text)).controlSize(.small) }
                }
                ForEach(l.message.videos, id: \.self) { VideoThumb(url: $0, height: 160) }
                ForEach(l.message.audios, id: \.self) { AudioChip(url: $0) }
                ForEach(Array(l.message.images.enumerated()), id: \.offset) { _, d in
                    if let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 160).clipShape(.rect(cornerRadius: 10))
                    }
                }
                if !l.message.text.isEmpty {
                    if user {
                        Text(l.message.text).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        MarkdownView(text: l.message.text)
                    }
                } else if current, let run {
                    PhaseStatus(run: run, typicalLoad: spec.flatMap { state.metrics.stats($0.id, .loadTime)?.typ })
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pending.isEmpty || !pendingVideos.isEmpty || !pendingAudios.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(pendingAudios, id: \.self) { url in
                            ZStack(alignment: .topTrailing) {
                                AudioChip(url: url).padding(.top, 6).padding(.trailing, 6)
                                Button("Remove attachment", systemImage: "xmark.circle.fill") { pendingAudios.removeAll { $0 == url } }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                        ForEach(pendingVideos, id: \.self) { url in
                            ZStack(alignment: .topTrailing) {
                                VideoThumb(url: url, height: 56)
                                Button("Remove attachment", systemImage: "xmark.circle.fill") { pendingVideos.removeAll { $0 == url } }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                        ForEach(Array(pending.enumerated()), id: \.offset) { i, d in
                            ZStack(alignment: .topTrailing) {
                                if let img = NSImage(data: d) {
                                    Image(nsImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 8))
                                }
                                Button("Remove attachment", systemImage: "xmark.circle.fill") { pending.remove(at: i) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button("Attach Image, Video or Audio", systemImage: "photo") { attach() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Attach Image, Video or Audio")
                TextField("Message \(spec?.displayName ?? "")", text: $input, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.plain).font(.title3)
                    .onSubmit(send).composerKeys().disabled(generating)
                    .focused($composerFocused)
                if generating {
                    Button("Stop", systemImage: "stop.fill", action: stop)
                        .labelStyle(.iconOnly).buttonStyle(.glass).help("Stop")
                } else {
                    Button("Send", systemImage: "arrow.up", action: send)
                        .labelStyle(.iconOnly).buttonStyle(.glassProminent).help("Send")
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty && pendingVideos.isEmpty && pendingAudios.isEmpty)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
    }

    /// Images are read now; videos stay files, because the model's processor samples frames from the file.
    private func add(_ urls: [URL]) {
        for url in urls {
            guard let t = UTType(filenameExtension: url.pathExtension) else { continue }
            if t.conforms(to: .movie) { pendingVideos.append(url) }
            else if t.conforms(to: .audio) { pendingAudios.append(url) }
            else if t.conforms(to: .image), let d = try? Data(contentsOf: url) { pending.append(d) }
        }
    }

    private func attach() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .movie, .audio]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { add(p.urls) }
    }

    private func stop() { task?.cancel(); task = nil; generating = false }

    /// The conversation as saved: text in the payload, attachments as files named by message and position.
    struct Record: Codable {
        struct Message: Codable { var role: String; var text: String; var at: Double; var images, videos, audios: [String] }
        var messages: [Message]
    }

    private func save(model: String) {
        var files: [String: Data] = [:], copies: [String: URL] = [:]
        let messages = lines.enumerated().map { i, line -> Record.Message in
            let m = line.message
            let images = m.images.enumerated().map { j, data in let n = "m\(i)-image\(j)"; files[n] = data; return n }
            let videos = m.videos.enumerated().map { j, url in let n = "m\(i)-video\(j).\(url.pathExtension)"; copies[n] = url; return n }
            let audios = m.audios.enumerated().map { j, url in let n = "m\(i)-audio\(j).\(url.pathExtension)"; copies[n] = url; return n }
            return .init(role: m.role.rawValue, text: m.text, at: line.at, images: images, videos: videos, audios: audios)
        }
        let title = lines.first { $0.message.role == .user }?.message.text.prefix(80).description ?? ""
        let item = HistoryItem(id: conversation, kind: .chat, title: title, model: model, createdAt: started ?? Date(),
                               payload: (try? JSONEncoder().encode(Record(messages: messages))) ?? Data())
        state.saveHistory(item, files: files, copy: copies)
    }

    private func open(_ item: HistoryItem) {
        guard let record = item.decode(Record.self) else { return }
        stop()
        let history = state.history
        Task {
            var restored: [Line] = []
            for m in record.messages {
                var images: [Data] = []
                for n in m.images { if let d = await history.data(item, n) { images.append(d) } }
                var videos: [URL] = [], audios: [URL] = []
                for n in m.videos { videos.append(await history.url(item, n)) }
                for n in m.audios { audios.append(await history.url(item, n)) }
                restored.append(Line(message: ChatMessage(role: ChatMessage.Role(rawValue: m.role) ?? .user, text: m.text,
                                                          images: images, videos: videos, audios: audios), at: m.at))
            }
            lines = restored
            started = item.createdAt
            conversation = item.id
            run = nil; error = nil; pending = []; pendingVideos = []; pendingAudios = []
            if specs.contains(where: { $0.id == item.model }) { modelID = item.model }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generating, !text.isEmpty || !pending.isEmpty || !pendingVideos.isEmpty || !pendingAudios.isEmpty, let spec else { return }
        let now = Date()
        if started == nil { started = now }
        let offset = now.timeIntervalSince(started ?? now)
        lines.append(Line(message: ChatMessage(role: .user, text: text, images: pending, videos: pendingVideos, audios: pendingAudios), at: offset))
        let history = lines.map(\.message)
        lines.append(Line(message: ChatMessage(role: .assistant, text: ""), at: offset))
        input = ""; pending = []; pendingVideos = []; pendingAudios = []; error = nil; generating = true
        run = Run(sent: now)
        Task { try? await Task.sleep(for: .seconds(1)); await state.refreshResidents() }
        let chat = state.chat, metrics = state.metrics
        task = Task {
            do {
                if history.contains(where: { !$0.videos.isEmpty }), await !chat.supportsVideo(spec) {
                    throw MediaUnsupported(model: spec.displayName, kind: "video", hint: "Qwen3.5 and the omni models do.")
                }
                if history.contains(where: { !$0.audios.isEmpty }), await !chat.supportsAudio(spec) {
                    throw MediaUnsupported(model: spec.displayName, kind: "audio", hint: "Omni models such as Gemma 3n do.")
                }
                let history = try await Self.withWAVAudio(history)
                for try await ev in try await chat.stream(model: spec, messages: history, options: ChatOptions()) {
                    switch ev {
                    case .delta(let s):
                        if run?.firstToken == nil {
                            run?.firstToken = Date(); run?.phase = .generating
                            if let start = started { lines[lines.count - 1].at = Date().timeIntervalSince(start) }
                        }
                        run?.chunks += 1
                        lines[lines.count - 1].message.text += s
                    case .done(_, let usage):
                        run?.ended = Date(); run?.usage = usage
                    case .progress(let p):
                        run?.apply(p)
                    case .toolCall: break
                    }
                }
                save(model: spec.id)
                if let r = run {
                    r.loadSeconds.map { metrics.record(spec.id, .loadTime, $0) }
                    r.firstTokenSeconds.map { metrics.record(spec.id, r.cached ? .firstTokenCached : .firstToken, $0) }
                    r.decodeRate.map { metrics.record(spec.id, .decodeRate, $0) }
                    r.promptRate.map { metrics.record(spec.id, .prefillRate, $0) }
                }
            } catch is CancellationError {
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if run?.ended == nil { run?.ended = Date() }
            generating = false
            composerFocused = true
        }
    }
}

extension ChatView {
    /// Omni models get WAV only (as the API path does): other attachments are decoded with the bundled ffmpeg.
    static func withWAVAudio(_ messages: [ChatMessage]) async throws -> [ChatMessage] {
        guard messages.contains(where: { $0.audios.contains { $0.pathExtension.lowercased() != "wav" } }) else { return messages }
        guard let decoder = AudioDecoder.bundled() else { return messages }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-chat-audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = messages
        for i in out.indices {
            for j in out[i].audios.indices where out[i].audios[j].pathExtension.lowercased() != "wav" {
                // decodeToWAV always names its output audio.wav, so each clip gets its own folder.
                let own = dir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
                out[i].audios[j] = try await decoder.decodeToWAV(.media(out[i].audios[j]), into: own)
            }
        }
        return out
    }
}

private struct MediaUnsupported: LocalizedError {
    let model: String, kind: String, hint: String
    var errorDescription: String? { "\(model) does not accept \(kind). \(hint)" }
}

/// An attached audio clip: file name and length.
private struct AudioChip: View {
    let url: URL
    @State private var seconds: Double?

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let seconds { Text(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds.rounded()) % 60)).font(.mono(.caption)).foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: "waveform") }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .task(id: url) { seconds = try? await AVURLAsset(url: url).load(.duration).seconds }
    }
}

/// A video's first frame with a play badge and its length.
private struct VideoThumb: View {
    let url: URL
    let height: CGFloat
    @State private var frame: NSImage?
    @State private var seconds: Double?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let frame { Image(nsImage: frame).resizable().scaledToFill() } else { Color.secondary.opacity(0.2) }
            }
            .frame(width: height * 16 / 9, height: height)
            .clipShape(.rect(cornerRadius: height > 80 ? 10 : 8))
            Label(seconds.map { String(format: "%d:%02d", Int($0) / 60, Int($0.rounded()) % 60) } ?? "video", systemImage: "play.fill")
                .font(.mono(.caption2)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: .capsule)
                .padding(4)
        }
        .task(id: url) {
            let asset = AVURLAsset(url: url)
            seconds = try? await asset.load(.duration).seconds
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            if let cg = try? await gen.image(at: .zero).image { frame = NSImage(cgImage: cg, size: .zero) }
        }
    }
}

/// What a reply is doing before its first token. Loading has no fraction from any engine, so its bar is this model's
/// typical load time when one was measured (labelled "about"); prompt processing is exact where the engine reports
/// it (llama.cpp) and indeterminate otherwise.
private struct PhaseStatus: View {
    let run: ChatView.Run
    let typicalLoad: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(run.phaseStart)
            let (label, fraction) = describe(elapsed)
            LiveProgress(label: label, fraction: fraction)
        }
    }

    private func describe(_ elapsed: Double) -> (String, Double?) {
        let t = String(format: "%.1f s", elapsed)
        switch run.phase {
        case .loading:
            guard let typ = typicalLoad, typ > 0.5 else { return ("Loading model · \(t)", nil) }
            return ("Loading model · \(t) of about \(String(format: "%.0f s", typ.rounded(.up)))", min(elapsed / typ, 0.95))
        case .prompt(let f?):
            return ("Reading prompt · \(Int((f * 100).rounded()))%", f)
        case .prompt(nil):
            return ("Reading prompt · \(t)", nil)
        case .waiting, .generating:
            return ("Waiting for the model…", nil)
        }
    }
}
