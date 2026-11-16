import AVFoundation
import AppKit
import SwiftUI
import SynapseCore

enum LiveMode: String, CaseIterable, Identifiable {
    case captions = "Captions", translate = "Translate", call = "Voice call", duplex = "Full duplex"
    var id: String { rawValue }
}

@MainActor @Observable
final class LiveModel {
    struct Line: Identifiable { let id: String; var role: String; var text: String; var final: Bool }

    var lines: [Line] = []
    var running = false
    var preparing = false
    var level: Float = 0
    var error: String?
    var latency: Double?

    private var session: RealtimeSession?
    private var audio: LiveAudio?
    private var muted = false
    private var task: Task<Void, Never>?

    var transcript: String { lines.map { "\($0.role): \($0.text)" }.joined(separator: "\n") }
    func clear() { lines = []; latency = nil; error = nil }

    func start(mode: LiveMode, services: RealtimeServices, chatModel: String, duplexModel: String,
               language: String, spoken: Bool, voice: String) async {
        guard !running else { return }
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Microphone access is denied. Allow Synapse under System Settings > Privacy & Security > Microphone."
            return
        }
        let s: RealtimeSession
        var update: [String: Any] = ["type": mode == .captions ? "transcription" : "realtime"]
        switch mode {
        case .captions:
            s = RealtimeSession(transcriptionOnly: true, services: services)
            update["audio"] = ["input": ["transcription": ["model": "parakeet-eou-120m"], "turn_detection": ["type": "server_vad"]]]
        case .translate:
            s = RealtimeSession(model: chatModel, services: services)
            update["translation_language"] = language
            update["output_modalities"] = [spoken ? "audio" : "text"]
            if spoken && !voice.isEmpty { update["audio"] = ["output": ["voice": voice]] }
        case .call:
            s = RealtimeSession(model: chatModel, services: services)
            update["output_modalities"] = ["audio"]
            if !voice.isEmpty { update["audio"] = ["output": ["voice": voice]] }
        case .duplex:
            s = RealtimeSession(model: duplexModel, services: services)
            update["output_modalities"] = ["audio"]
        }
        let a = LiveAudio()
        do {
            try a.start(voiceProcessing: mode == .call || mode == .duplex,   // AEC; see LiveAudio
                        onChunk: { pcm in Task { await s.appendAudio(pcm24k: pcm) } },
                        onLevel: { l in Task { @MainActor [weak self] in self?.level = l } })
        } catch {
            self.error = "Could not start the microphone: \(error.localizedDescription)"
            await s.close(); return
        }
        session = s; audio = a; running = true; preparing = true; muted = false
        task = Task { [weak self] in
            for await data in s.events { self?.handle(data, session: s, mode: mode) }
            self?.finish()
        }
        if let d = try? JSONSerialization.data(withJSONObject: ["type": "session.update", "session": update]) { await s.handle(d) }
    }

    func stop() {
        audio?.stop(); audio = nil
        let s = session; session = nil
        Task { await s?.close() }   // ends the events stream, which calls finish()
        running = false; preparing = false; level = 0
    }

    private func finish() { task = nil; running = false; preparing = false; level = 0 }

    private func upsert(_ id: String, role: String, text: String, final: Bool, append: Bool) {
        if let i = lines.firstIndex(where: { $0.id == id }) {
            lines[i].text = append ? lines[i].text + text : text
            lines[i].final = final
        } else { lines.append(Line(id: id, role: role, text: text, final: final)) }
    }

    private func handle(_ data: Data, session s: RealtimeSession, mode: LiveMode) {
        guard let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = e["type"] as? String else { return }
        switch t {
        case "session.updated": preparing = false
        case "conversation.item.input_audio_transcription.delta":
            if let id = e["item_id"] as? String, let d = e["delta"] as? String { upsert(id, role: "You", text: d, final: false, append: true) }
        case "conversation.item.input_audio_transcription.completed":
            if let id = e["item_id"] as? String, let d = e["transcript"] as? String { upsert(id, role: "You", text: d, final: true, append: false) }
        case "response.created": muted = false
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            if let id = e["response_id"] as? String, let d = e["delta"] as? String { upsert(id, role: "Assistant", text: d, final: false, append: true) }
        case "response.output_audio.delta":
            if !muted, let b = e["delta"] as? String, let d = Data(base64Encoded: b) { audio?.play(pcm16: d) }
        case "input_audio_buffer.speech_started":
            muted = true; audio?.flush()   // barge-in: cut local playback now
        case "response.done":
            if let id = (e["response"] as? [String: Any])?["id"] as? String, let i = lines.firstIndex(where: { $0.id == id }) { lines[i].final = true }
            if mode == .call { Task { let l = await s.lastFirstAudioLatency; self.latency = l } }
        case "error":
            error = (e["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
        default: break
        }
    }
}

struct LiveView: View {
    @Environment(AppState.self) private var state
    @State private var model = LiveModel()
    @State private var mode: LiveMode = .captions
    @State private var chatModel = ""
    @State private var duplexModel = ""
    @State private var language = "Spanish"
    @State private var spoken = false
    @State private var voice = ""
    private let languages = ["Spanish", "French", "German", "Italian", "Portuguese", "Japanese", "Chinese", "Korean", "English"]

    private var needsChat: Bool { mode == .translate || mode == .call }
    private var canStart: Bool {
        switch mode {
        case .captions: state.downloadedRealtimeBase
        case .duplex: !duplexModel.isEmpty
        default: state.downloadedRealtimeBase && !chatModel.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Mode", selection: $mode) { ForEach(LiveMode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).disabled(model.running)
                    if needsChat {
                        Picker("Chat model", selection: $chatModel) {
                            ForEach(state.downloadedChatSpecs) { Text($0.displayName).tag($0.id) }
                        }.disabled(model.running)
                    }
                    if mode == .translate {
                        Picker("Translate to", selection: $language) { ForEach(languages, id: \.self) { Text($0) } }.disabled(model.running)
                        Toggle("Speak the translation", isOn: $spoken).disabled(model.running)
                    }
                    if mode == .call || (mode == .translate && spoken) {
                        TextField("Voice (optional)", text: $voice).disabled(model.running)
                    }
                    if mode == .duplex {
                        Picker("Duplex model", selection: $duplexModel) {
                            ForEach(state.downloadedDuplexSpecs) { Text($0.displayName).tag($0.id) }
                        }.disabled(model.running)
                        Label("Experimental", systemImage: "flask").foregroundStyle(.orange)
                    }
                    if !canStart && !model.running {
                        Text(mode == .duplex ? "Download a full-duplex model in Models."
                             : "Download Parakeet EOU, Silero VAD, PocketTTS" + (mode == .captions ? "" : " and a Qwen chat model") + " in Models.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    HStack {
                        Button(model.running ? "Stop" : "Start", systemImage: model.running ? "stop.circle.fill" : "mic.circle.fill") {
                            if model.running { model.stop() } else {
                                Task { await model.start(mode: mode, services: state.realtime, chatModel: chatModel,
                                                         duplexModel: duplexModel, language: language, spoken: spoken, voice: voice) }
                            }
                        }
                        .keyboardShortcut(.defaultAction).disabled(!model.running && !canStart)
                        if model.running {
                            ProgressView(value: Double(model.level)).frame(width: 120).accessibilityLabel("Microphone level")
                            Text(model.preparing ? "Preparing models…" : "Listening").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode == .call, let l = model.latency { Text(String(format: "first audio in %.1f s", l)).font(.caption).foregroundStyle(.secondary) }
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.transcript, forType: .string)
                        }.disabled(model.lines.isEmpty)
                        Button("Clear", systemImage: "trash") { model.clear() }.disabled(model.lines.isEmpty)
                    }
                    if let e = model.error { Text(e).font(.callout).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.lines) { l in
                            Text(mode == .captions ? l.text : "\(l.role): \(l.text)")
                                .foregroundStyle(l.final ? .primary : .secondary)
                                .font(mode == .captions ? .title3 : .body)
                                .frame(maxWidth: .infinity, alignment: .leading).id(l.id)
                        }
                    }.padding()
                }
                .onChange(of: model.lines.last?.text) { if let id = model.lines.last?.id { proxy.scrollTo(id) } }
            }
            .accessibilityLabel("Live transcript")
        }
        .navigationTitle("Live")
        .task { await state.refreshModels() }
        .onAppear { if chatModel.isEmpty { chatModel = state.downloadedChatSpecs.first?.id ?? "" } }
        .onChange(of: state.downloadedChatSpecs.count) { if chatModel.isEmpty { chatModel = state.downloadedChatSpecs.first?.id ?? "" } }
        .onChange(of: state.downloadedDuplexSpecs.count) { if duplexModel.isEmpty { duplexModel = state.downloadedDuplexSpecs.first?.id ?? "" } }
        .onDisappear { if model.running { model.stop() } }
    }
}
