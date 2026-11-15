import AppKit
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppState.self) private var state
    @State private var modelID = ""
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var pending: [Data] = []
    @State private var generating = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    private var specs: [ModelSpec] { state.downloadedChatSpecs }

    var body: some View {
        Group {
            if specs.isEmpty {
                ContentUnavailableView("No chat model", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Download a Qwen model in Models"))
            } else {
                VStack(spacing: 0) {
                    transcript
                    Divider()
                    composer
                }
            }
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItemGroup {
                if !specs.isEmpty {
                    Picker("Model", selection: $modelID) {
                        ForEach(specs) { Text($0.displayName).tag($0.id) }
                    }
                }
                Button("New Chat", systemImage: "square.and.pencil") { stop(); messages = []; pending = []; error = nil }
                    .help("New Chat")
            }
        }
        .task { await state.refreshModels() }
        .onAppear(perform: pickModel)
        .onChange(of: specs.map(\.id)) { pickModel() }
    }

    private func pickModel() {
        if !specs.contains(where: { $0.id == modelID }) { modelID = specs.first?.id ?? "" }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in bubble(m) }
                    if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .onChange(of: messages.last?.text) { proxy.scrollTo("end") }
            .onChange(of: messages.count) { proxy.scrollTo("end") }
        }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        let user = m.role == .user
        return HStack {
            if user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(m.images.enumerated()), id: \.offset) { _, d in
                    if let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !m.text.isEmpty { Text(m.text).textSelection(.enabled) }
                else if !user { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(user ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            if !user { Spacer(minLength: 60) }
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
                                    Image(nsImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                Button { pending.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove attachment")
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom) {
                Button("Attach Image", systemImage: "photo") { attach() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Attach Image").accessibilityLabel("Attach Image")
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder)
                    .onSubmit(send).disabled(generating)
                if generating {
                    Button("Stop", systemImage: "stop.circle.fill", action: stop).accessibilityLabel("Stop")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty)
                }
            }
        }
        .padding()
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
        guard !generating, !text.isEmpty || !pending.isEmpty,
              let spec = specs.first(where: { $0.id == modelID }) else { return }
        messages.append(ChatMessage(role: .user, text: text, images: pending))
        let history = messages
        messages.append(ChatMessage(role: .assistant, text: ""))
        input = ""; pending = []; error = nil; generating = true
        let chat = state.chat
        task = Task {
            do {
                for try await ev in try await chat.stream(model: spec, messages: history, options: ChatOptions()) {
                    if case .delta(let s) = ev { messages[messages.count - 1].text += s }
                }
            } catch is CancellationError {
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            generating = false
        }
    }
}
