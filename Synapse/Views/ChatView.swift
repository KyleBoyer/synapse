import AppKit
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppState.self) private var state
    /// A conversation line plus when it started, relative to the conversation's first message.
    struct Line { var message: ChatMessage; var at: Double }
    /// The run being measured: send time, first token, tokens so far, final usage.
    struct Run {
        var sent = Date()
        var firstToken: Date?
        var chunks = 0
        var ended: Date?
        var usage: ChatUsage?
        var firstTokenSeconds: Double? { firstToken.map { $0.timeIntervalSince(sent) } }
        var decodeRate: Double? {
            guard let f = firstToken else { return nil }
            let tokens = Double((usage?.completionTokens ?? chunks) - 1)
            let t = (ended ?? Date()).timeIntervalSince(f)
            return t > 0.05 && tokens > 0 ? tokens / t : nil
        }
        var promptRate: Double? {
            guard let u = usage, let ttft = firstTokenSeconds, ttft > 0 else { return nil }
            return Double(u.promptTokens) / ttft
        }
    }

    @State private var modelID = ""
    @State private var lines: [Line] = []
    @State private var started: Date?
    @State private var input = ""
    @State private var pending: [Data] = []
    @State private var generating = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var run: Run?
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
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItemGroup {
                if !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: $modelID, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                }
                Button("New Chat", systemImage: "square.and.pencil") { stop(); lines = []; started = nil; pending = []; error = nil; run = nil }
                    .help("New Chat")
            }
        }
        .task { await state.refreshModels() }
        .onAppear { pickModel(); composerFocused = true }
        #if DEBUG
        // `-autoSendPrompt "..."` sends one message after launch, so streaming states can be captured without typing.
        .task(id: spec?.id) {
            guard let p = UserDefaults.standard.string(forKey: "autoSendPrompt"), !p.isEmpty, lines.isEmpty, spec != nil else { return }
            input = p; send()
        }
        #endif
        .onChange(of: specs.map(\.id)) { pickModel() }
        .onChange(of: generating) { state.setActive(.chat, generating) }
    }

    private func pickModel() {
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
                reading("First token", r?.firstTokenSeconds.map { String(format: "%.2f s", $0) }, .firstToken),
                reading("Decode", r?.decodeRate.map { Metric.decodeRate.format($0) + " tok/s" }, .decodeRate, live: generating),
                reading("Prompt", r?.usage.map { u in
                    "\(u.promptTokens) tok" + (r?.promptRate.map { " · " + Metric.prefillRate.format($0) + "/s" } ?? "")
                }, .prefillRate),
                Reading(label: "Output", value: r.map { "\($0.usage?.completionTokens ?? $0.chunks) tok" } ?? "–"),
                Reading(label: "Resident", value: resident.map { gigabytes($0.bytes) } ?? "not loaded"),
            ],
            history: state.metrics.history(spec.id, .decodeRate), historyMetric: .decodeRate,
            running: generating,
            api: "POST /v1/chat/completions\nmodel: \(spec.id)")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if lines.isEmpty {
                        Text("Send a message or drop an image to try \(spec?.displayName ?? "the model").")
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
                Text(user ? "You" : (spec?.displayName ?? "Model")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(l.message.images.enumerated()), id: \.offset) { _, d in
                    if let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 160).clipShape(.rect(cornerRadius: 10))
                    }
                }
                if !l.message.text.isEmpty {
                    Text(l.message.text)
                        .font(user ? .title3 : .subtitle)
                        .foregroundStyle(user ? .secondary : .primary)
                        .textSelection(.enabled)
                } else if current {
                    Text("Waiting for first token…").font(.callout).foregroundStyle(Color.live)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pending.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
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
                Button("Attach Image", systemImage: "photo") { attach() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Attach Image")
                TextField("Message \(spec?.displayName ?? "")", text: $input, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.plain).font(.title3)
                    .onSubmit(send).disabled(generating)
                    .focused($composerFocused)
                if generating {
                    Button("Stop", systemImage: "stop.fill", action: stop)
                        .labelStyle(.iconOnly).buttonStyle(.glass).help("Stop")
                } else {
                    Button("Send", systemImage: "arrow.up", action: send)
                        .labelStyle(.iconOnly).buttonStyle(.glassProminent).help("Send")
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
        .dropDestination(for: URL.self) { urls, _ in
            pending += urls.compactMap(Self.imageData); return true
        }
    }

    private static func imageData(_ url: URL) -> Data? {
        guard let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func attach() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { pending += p.urls.compactMap(Self.imageData) }
    }

    private func stop() { task?.cancel(); task = nil; generating = false }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generating, !text.isEmpty || !pending.isEmpty, let spec else { return }
        let now = Date()
        if started == nil { started = now }
        let offset = now.timeIntervalSince(started ?? now)
        lines.append(Line(message: ChatMessage(role: .user, text: text, images: pending), at: offset))
        let history = lines.map(\.message)
        lines.append(Line(message: ChatMessage(role: .assistant, text: ""), at: offset))
        input = ""; pending = []; error = nil; generating = true
        run = Run(sent: now)
        Task { try? await Task.sleep(for: .seconds(1)); await state.refreshResidents() }
        let chat = state.chat, metrics = state.metrics
        task = Task {
            do {
                for try await ev in try await chat.stream(model: spec, messages: history, options: ChatOptions()) {
                    switch ev {
                    case .delta(let s):
                        if run?.firstToken == nil {
                            run?.firstToken = Date()
                            if let start = started { lines[lines.count - 1].at = Date().timeIntervalSince(start) }
                        }
                        run?.chunks += 1
                        lines[lines.count - 1].message.text += s
                    case .done(_, let usage):
                        run?.ended = Date(); run?.usage = usage
                    default: break
                    }
                }
                if let r = run {
                    r.firstTokenSeconds.map { metrics.record(spec.id, .firstToken, $0) }
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
