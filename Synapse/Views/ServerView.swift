import Darwin
import SwiftUI
import SynapseCore

struct ServerView: View {
    @Environment(AppState.self) private var state
    @State private var portText = ""
    @State private var showKey = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Connect a client") {
                LabeledContent("Host") {
                    HStack {
                        Text(base).font(.mono()).foregroundStyle(.primary).textSelection(.enabled)
                        Button("Copy") { copy(base) }
                    }
                }
                LabeledContent("API key") {
                    Text(state.settings.allowLAN ? "the key below" : "any value (local only, no key needed)").foregroundStyle(.secondary)
                }
                Text("Give any client just the host and key. Synapse serves OpenAI Chat Completions, Completions and Responses and Anthropic Messages, streaming or not, at the host with or without /v1, and accepts the key as Authorization: Bearer (OpenAI) or x-api-key (Anthropic).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Enable API server", isOn: $state.settings.serverEnabled)
                HStack {
                    LabeledContent("Port") { TextField("Port", text: $portText).labelsHidden().font(.mono()).frame(width: 80) }
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort).disabled(Int(portText) == state.settings.port)
                }
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(state.serverStatus.label)
                    Spacer()
                    Text(base).font(.mono()).textSelection(.enabled)
                }
            }
            Section("Network") {
                Toggle("Allow connections from other devices (LAN)", isOn: $state.settings.allowLAN)
                Text("When on, every request needs the API key, sent as \"Authorization: Bearer <key>\", as \"x-api-key: <key>\", or as a /k/<key> path prefix. macOS will ask to allow incoming connections.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("API key")
                    Text(showKey ? state.settings.apiKey : String(repeating: "•", count: 24)).font(.mono(.caption)).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                    Button("Copy") { copy(state.settings.apiKey) }
                    Button("Regenerate") { state.settings.apiKey = Settings.generateKey() }
                }
            }
            Section("Bazarr") {
                Text("Settings → Providers → Whisper → Endpoint:").font(.caption)
                HStack {
                    Text(bazarrEndpoint).font(.mono(.callout)).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { copy(bazarrEndpoint) }
                }
                if !state.settings.allowLAN {
                    Text("Bazarr on another machine needs LAN access turned on.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Library roots for path jobs") {
                Text("POST /v1/jobs only accepts files inside these folders or a watched folder.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(state.settings.libraryRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root).font(.mono(.callout)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            state.settings.libraryRoots.removeAll { $0 == root }
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { addRoot() }
            }
            Section("Routes") {
                ForEach(Self.routes, id: \.0) { r in
                    LabeledContent { Text(r.1).foregroundStyle(.secondary) } label: { Text(r.0).font(.mono(.callout)) }
                }
            }
            Section("Examples") {
                ForEach(examples, id: \.self) { ex in
                    HStack(alignment: .top) {
                        Text(ex).font(.mono(.caption)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { copy(ex) }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server")
        .onAppear { portText = String(state.settings.port) }
        .task {
            while !Task.isCancelled {
                await state.refreshServerStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static let routes: [(String, String)] = [
        ("POST /v1/chat/completions", "OpenAI chat and vision"),
        ("POST /v1/completions", "OpenAI legacy text completion"),
        ("POST /v1/responses", "OpenAI Responses, image tool"),
        ("POST /v1/messages", "Anthropic Messages"),
        ("POST /v1/audio/transcriptions", "OpenAI transcription, speaker labels"),
        ("POST /v1/audio/speech", "OpenAI text to speech"),
        ("POST /v1/audio/generations", "Sound and music"),
        ("POST /v1/embeddings", "OpenAI embeddings"),
        ("POST /v1/rerank", "Cohere/Jina rerank"),
        ("POST /v1/images/generations", "OpenAI images"),
        ("POST /v1/videos", "OpenAI video generation"),
        ("GET /v1/realtime", "Realtime WebSocket"),
        ("POST /asr", "Bazarr Whisper provider"),
        ("POST /v1/jobs", "Subtitle a file by path"),
        ("GET /v1/models", "Downloaded models"),
    ]

    private var base: String {
        let host = state.settings.allowLAN ? (Self.lanIP() ?? "127.0.0.1") : "127.0.0.1"
        return "http://\(host):\(state.settings.port)"
    }

    private var bazarrEndpoint: String {
        state.settings.allowLAN ? "\(base)/k/\(state.settings.apiKey)" : base
    }

    private var examples: [String] {
        let auth = state.settings.allowLAN ? " -H 'Authorization: Bearer \(state.settings.apiKey)'" : ""
        return [
            "curl\(auth) \(base)/v1/audio/transcriptions -F file=@movie.mkv -F response_format=srt",
            "curl\(auth) \(base)/v1/jobs -H 'content-type: application/json' -d '{\"path\":\"/Volumes/Media/movie.mkv\"}'",
            "curl\(auth) \(base)/v1/models",
            "curl\(auth) \(base)/v1/chat/completions -H 'content-type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}'",
            "curl\(state.settings.allowLAN ? " -H 'x-api-key: \(state.settings.apiKey)'" : "") \(base)/v1/messages -H 'content-type: application/json' -d '{\"model\":\"qwen3.5-0.8b\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}'",
        ]
    }

    private var statusColor: Color {
        switch state.serverStatus {
        case .running: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private func applyPort() {
        guard let p = Int(portText), (1...65535).contains(p) else { portText = String(state.settings.port); return }
        state.settings.port = p
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url,
              !state.settings.libraryRoots.contains(url.path) else { return }
        state.settings.libraryRoots.append(url.path)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// First IPv4 address on an en* interface.
    static func lanIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
