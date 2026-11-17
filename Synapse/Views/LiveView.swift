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
    struct Line: Identifiable { let id: String; var role: String; var text: String; var final: Bool; var at: Double = 0 }

    var lines: [Line] = []
    var running = false
    var preparing = false
    var level: Float = 0
    var error: String?
    var latency: Double?
    /// Running camera, when Voice call was started with Camera on.
    private(set) var camera: LiveCamera?
    /// When the session started; lines carry their offset from it as timecode.
    var started: Date?

    private var session: RealtimeSession?
    private var audio: LiveAudio?
    private var muted = false
    private var task: Task<Void, Never>?

    var transcript: String { lines.map { "\($0.role): \($0.text)" }.joined(separator: "\n") }
    func clear() { lines = []; latency = nil; error = nil }

    func start(mode: LiveMode, services: RealtimeServices, chatModel: String, duplexModel: String,
               language: String, spoken: Bool, voice: String, camera useCamera: Bool = false) async {
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
        if useCamera && mode == .call {
            let cam = LiveCamera()
            do { try await cam.start(); camera = cam } catch {
                self.error = error.localizedDescription
                a.stop(); await s.close(); return
            }
        }
        session = s; audio = a; running = true; preparing = true; muted = false; started = Date()
        task = Task { [weak self] in
            for await data in s.events { self?.handle(data, session: s, mode: mode) }
            self?.finish()
        }
        if let d = try? JSONSerialization.data(withJSONObject: ["type": "session.update", "session": update]) { await s.handle(d) }
    }

    func stop() {
        audio?.stop(); audio = nil
        camera?.stop(); camera = nil
        let s = session; session = nil
        Task { await s?.close() }   // ends the events stream, which calls finish()
        running = false; preparing = false; level = 0
    }

    private func finish() { task = nil; running = false; preparing = false; level = 0; camera?.stop(); camera = nil }

    /// Puts what the camera sees into the conversation as the user starts talking, so it precedes their words.
    private func sendFrame(_ s: RealtimeSession) {
        guard let jpeg = camera?.latestJPEG() else { return }
        let event: [String: Any] = ["type": "conversation.item.create", "item": [
            "type": "message", "role": "user",
            "content": [["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]]]
        if let d = try? JSONSerialization.data(withJSONObject: event) { Task { await s.handle(d) } }
    }

    private func upsert(_ id: String, role: String, text: String, final: Bool, append: Bool) {
        if let i = lines.firstIndex(where: { $0.id == id }) {
            lines[i].text = append ? lines[i].text + text : text
            lines[i].final = final
        } else {
            lines.append(Line(id: id, role: role, text: text, final: final, at: started.map { Date().timeIntervalSince($0) } ?? 0))
        }
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
            sendFrame(s)
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
    @State private var cameraOn = false
    private let languages = ["Spanish", "French", "German", "Italian", "Portuguese", "Japanese", "Chinese", "Korean", "English"]

    private var needsChat: Bool { mode == .translate || mode == .call }
    /// An omni model that hears the call and answers in its own voice, with no speech synthesis.
    private var ownVoice: Bool { mode == .call && Catalog.spec(chatModel).map(OmniVoices.canSpeak) == true }
    private var canStart: Bool {
        switch mode {
        case .captions: state.downloadedRealtimeBase
        case .duplex: !duplexModel.isEmpty
        default: state.downloadedRealtimeBase && !chatModel.isEmpty
        }
    }
    /// Captions have nothing to set; the options card shows only when it holds a control or a missing-model note.
    private var hasOptions: Bool { mode != .captions || (!canStart && !model.running) }
    /// The model doing the talking in this mode, for the readout.
    private var speakerID: String {
        switch mode {
        case .captions: "parakeet-eou-120m"
        case .duplex: duplexModel
        default: chatModel
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            stage
            ScrollView {
                VStack(spacing: 12) { readout; if hasOptions { options } }.padding(16).frame(maxWidth: .infinity)
            }
            .frame(width: 320)
            .scrollClipDisabled()
            
        }
        .safeAreaInset(edge: .bottom) { micBar.padding([.horizontal, .bottom], 16) }
        .navigationTitle("Live")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) { ForEach(LiveMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).disabled(model.running)
            }
        }
        .task { await state.refreshModels() }
        .onAppear { if chatModel.isEmpty { chatModel = state.downloadedChatSpecs.first?.id ?? "" } }
        .onChange(of: state.downloadedChatSpecs.count) { if chatModel.isEmpty { chatModel = state.downloadedChatSpecs.first?.id ?? "" } }
        .onChange(of: state.downloadedDuplexSpecs.count, initial: true) { if duplexModel.isEmpty { duplexModel = state.downloadedDuplexSpecs.first?.id ?? "" } }
        .onChange(of: model.running) { state.setActive(.live, model.running) }
        .onChange(of: model.latency) { if let l = model.latency, !chatModel.isEmpty { state.metrics.record(chatModel, .firstAudio, l) } }
        .onDisappear { if model.running { model.stop() } }
        #if DEBUG
        // `-liveMode "Voice call" -liveCamera YES` preselects a mode and the camera, so the options can be captured.
        .onAppear {
            if let m = UserDefaults.standard.string(forKey: "liveMode").flatMap(LiveMode.init(rawValue:)) { mode = m }
            if let m = UserDefaults.standard.string(forKey: "liveModel") { chatModel = m }
            if UserDefaults.standard.bool(forKey: "liveCamera") { cameraOn = true }
        }
        #endif
    }

    @ViewBuilder private var stage: some View {
        if mode == .captions {
            // Captions sit where subtitles do: bottom third, centered, the newest line brightest.
            VStack(spacing: 10) {
                Spacer()
                if model.lines.isEmpty {
                    Text(model.running ? "Listening…" : "Start the microphone to caption speech live.")
                        .font(.subtitle).foregroundStyle(.secondary)
                }
                ForEach(model.lines.suffix(3)) { l in
                    Text(l.text)
                        .font(.system(size: 28, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(l.final ? Color.primary : Color.live)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 40).padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain).accessibilityLabel("Live captions")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let cam = model.camera {
                            CameraPreview(session: cam.session)
                                .frame(maxWidth: 392, minHeight: 220, maxHeight: 220)
                                .clipShape(.rect(cornerRadius: 14))
                                .accessibilityLabel("Camera preview")
                        }
                        if model.lines.isEmpty {
                            Text(emptyText).font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(model.lines) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(timecode(l.at)).font(.mono(.caption)).foregroundStyle(l.final ? Color.secondary : Color.live)
                                    .frame(width: 82, alignment: .leading)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(l.role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(l.text).font(l.role == "You" ? .title3 : .subtitle)
                                        .foregroundStyle(l.role == "You" ? .secondary : .primary).textSelection(.enabled)
                                }
                            }
                            .id(l.id)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: 820, alignment: .leading)
                }
                .onChange(of: model.lines.last?.text) { if let id = model.lines.last?.id { proxy.scrollTo(id) } }
            }
            .accessibilityLabel("Live transcript")
        }
    }

    private var emptyText: String {
        switch mode {
        case .translate: "Speak, and the translation appears here."
        case .call: "Start the call and talk. Interrupt any time."
        case .duplex: "Full duplex: the model listens and speaks at the same time."
        case .captions: ""
        }
    }

    private var readout: some View {
        let spec = Catalog.spec(speakerID)
        return BurnIn(
            name: spec?.displayName ?? "No model", modelID: speakerID.isEmpty ? "–" : speakerID,
            readings: [
                Reading(label: "State", value: model.running ? (model.preparing ? "loading models" : "listening") : "stopped", live: model.running),
                Reading(label: "Mic level", value: model.running ? String(format: "%3.0f%%", model.level * 100) : "–", live: model.running),
                model.latency.map { Reading(label: "First audio", value: String(format: "%.2f s", $0)) }
                    ?? Reading(label: "First audio", value: state.metrics.typical(speakerID, .firstAudio) ?? "–", muted: true),
                Reading(label: "Lines", value: "\(model.lines.count)"),
            ] + (mode == .call ? [Reading(label: "Camera", value: model.camera != nil ? "on · 512 px" : "off", live: model.camera != nil),
                                  Reading(label: "Voice", value: ownVoice ? "model's own" : (voice.isEmpty ? "PocketTTS" : voice))] : []) + [
                Reading(label: "Resident", value: state.resident(speakerID).map { gigabytes($0.bytes) } ?? "not loaded"),
            ],
            history: state.metrics.history(speakerID, .firstAudio), historyMetric: .firstAudio,
            running: model.running,
            api: "GET /v1/realtime\nmodel: \(speakerID)" + (mode == .captions ? "\nintent: transcription" : ""),
            apiCopy: "ws://127.0.0.1:\(state.settings.port)/v1/realtime?model=\(speakerID)" + (mode == .captions ? "&intent=transcription" : ""))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            if needsChat {
                Picker("Chat model", selection: $chatModel) {
                    ForEach(state.downloadedChatSpecs) { Text($0.displayName).tag($0.id) }
                }
            }
            if mode == .translate {
                Picker("Translate to", selection: $language) { ForEach(languages, id: \.self) { Text($0) } }
                Toggle("Speak the translation", isOn: $spoken)
            }
            if mode == .call {
                Toggle("Camera", systemImage: "video", isOn: $cameraOn)
                    .help("Show the model what the camera sees each time you start talking. Needs a Qwen3.5 model.")
            }
            if ownVoice {
                Label("Hears you and answers in its own voice.", systemImage: "waveform.and.person.filled")
                    .font(.callout).foregroundStyle(.secondary)
            } else if mode == .call || (mode == .translate && spoken) {
                TextField("Voice (optional)", text: $voice).textFieldStyle(.roundedBorder)
            }
            if mode == .duplex {
                Picker("Duplex model", selection: $duplexModel) {
                    ForEach(state.downloadedDuplexSpecs) { Text($0.displayName).tag($0.id) }
                }
                Label("Experimental. Needs the RAM shown in Models.", systemImage: "flask").font(.callout).foregroundStyle(.orange)
            }
            if !canStart && !model.running {
                Label(mode == .duplex ? "Download a full-duplex model in Models."
                      : "Download Parakeet EOU, Silero VAD, PocketTTS" + (mode == .captions ? "" : " and a Qwen chat model") + " in Models.",
                      systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.orange)
            }
        }
        .disabled(model.running)
        .padding(14)
        .frame(width: 288, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var micBar: some View {
        HStack(spacing: 14) {
            Button {
                if model.running { model.stop() } else {
                    Task { await model.start(mode: mode, services: state.realtime, chatModel: chatModel,
                                             duplexModel: duplexModel, language: language, spoken: spoken, voice: voice,
                                             camera: cameraOn) }
                }
            } label: {
                Label(model.running ? "Stop" : "Start", systemImage: model.running ? "stop.fill" : "mic.fill").frame(minWidth: 80)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction).disabled(!model.running && !canStart)
            if model.running {
                ProgressView(value: Double(model.level)).tint(.live).frame(width: 140).accessibilityLabel("Microphone level")
                Text(model.preparing ? "Loading models…" : "Listening").foregroundStyle(.secondary)
            } else if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.transcript, forType: .string)
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.lines.isEmpty).help("Copy transcript")
            Button("Clear", systemImage: "trash") { model.clear() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.lines.isEmpty).help("Clear")
        }
        .glassBar()
    }
}
