import AVFoundation
import SwiftUI
import SynapseCore

/// Plays Float PCM as it arrives (or a finished clip). Output-only (AudioQueue):
/// AVAudioEngine would open the HAL input side too and trigger the microphone prompt.
@MainActor
final class SpeakPlayer {
    private var queue: AudioQueueRef?
    private var rate = 24000
    private var pending: [Float] = []
    private var started = false
    private var outstanding = 0
    private var finish: (@MainActor @Sendable () -> Void)?
    /// Held until 150 ms has arrived, so a slow first chunk does not stutter.
    private let prebuffer = 3600
    /// Playback failures are reported here; synthesis itself still succeeds.
    var onError: (@MainActor (String) -> Void)?

    func begin(rate: Int) {
        stop()
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var q: AudioQueueRef?
        let status = AudioQueueNewOutputWithDispatchQueue(&q, &asbd, 0, .main) { [weak self] q, buf in
            AudioQueueFreeBuffer(q, buf)
            MainActor.assumeIsolated {
                guard let self, self.queue == q else { return }
                self.outstanding -= 1
                if self.outstanding == 0, let f = self.finish { self.finish = nil; f() }
            }
        }
        if status == noErr { queue = q } else { onError?("Could not open the audio output (\(status)).") }
    }

    func enqueue(_ samples: [Float], final: Bool = false, onFinish: (@MainActor @Sendable () -> Void)? = nil) {
        pending += samples
        guard let queue, final || started || pending.count >= prebuffer else { return }
        let out = pending; pending = []
        if !out.isEmpty {
            let bytes = UInt32(out.count * 4)
            var buf: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, bytes, &buf) == noErr, let buf {
                out.withUnsafeBytes { buf.pointee.mAudioData.copyMemory(from: $0.baseAddress!, byteCount: Int(bytes)) }
                buf.pointee.mAudioDataByteSize = bytes
                if AudioQueueEnqueueBuffer(queue, buf, 0, nil) == noErr { outstanding += 1 } else { AudioQueueFreeBuffer(queue, buf) }
            }
        }
        if !started {
            started = true
            let s = AudioQueueStart(queue, nil)
            // Output devices that also record (some remote-desktop audio devices) make macOS ask for the microphone
            // before playback; if that is denied, starting fails and the user needs to know why there is no sound.
            if s != noErr {
                onError?("Playback did not start (\(s)). If macOS asked for the microphone, your output device also records; allow access or pick another output in System Settings > Sound.")
            }
        }
        guard let onFinish else { return }
        if outstanding == 0 { onFinish() } else { finish = onFinish }
    }

    func stop() {
        pending = []; started = false; outstanding = 0; finish = nil
        if let queue { self.queue = nil; AudioQueueDispose(queue, true) }
    }
}

@MainActor @Observable
final class SpeakModel {
    struct Clip: Identifiable {
        let id = UUID()
        let text: String
        let model: String
        let voice: String
        let samples: [Float]
        let rate: Int
        /// The file as the model wrote it (stereo for Stable Audio); saved as is when present.
        var wav: Data? = nil
        var seconds: Double { Double(samples.count) / Double(rate) }
    }

    var clips: [Clip] = []
    var running = false
    var preparing = false
    var error: String?
    var playing: UUID?
    private(set) var started: Date?
    private(set) var firstAudio: Double?
    private(set) var audioSeconds = 0.0
    private(set) var elapsed: Double?
    private(set) var rate = 0
    private var task: Task<Void, Never>?
    private let player = SpeakPlayer()

    init() { player.onError = { [weak self] in self?.error = $0 } }

    func speak(text: String, spec: ModelSpec, voice: String, state: AppState) {
        let speech = state.speech, metrics = state.metrics
        error = nil; running = true; firstAudio = nil; audioSeconds = 0; elapsed = nil; playing = nil
        started = nil
        task = Task {
            preparing = state.resident("speech:\(spec.id)") == nil
            defer { running = false; preparing = false }
            var samples: [Float] = []
            do {
                let (sr, pcm) = try await speech.synthesize(model: spec, text: text, voice: voice, speed: 1)
                rate = sr
                let start = Date(); started = start // warm clock: the model is ready once the stream exists
                player.begin(rate: sr)
                for try await frame in pcm {
                    if firstAudio == nil { firstAudio = Date().timeIntervalSince(start); preparing = false }
                    samples += frame
                    audioSeconds = Double(samples.count) / Double(sr)
                    player.enqueue(frame)
                }
                player.enqueue([], final: true)
                elapsed = Date().timeIntervalSince(start)
                if let f = firstAudio { metrics.record(spec.id, .ttsFirstAudio, f) }
                if let e = elapsed, audioSeconds > 0 { metrics.record(spec.id, .ttsSpeed, audioSeconds / e) }
            } catch is CancellationError {
                player.stop()
            } catch { self.error = error.localizedDescription; player.stop() }
            if !samples.isEmpty { clips.insert(Clip(text: text, model: spec.id, voice: voice, samples: samples, rate: rate), at: 0) }
        }
    }

    func stop() { task?.cancel(); player.stop(); playing = nil }

    func toggle(_ clip: Clip) {
        if playing == clip.id { player.stop(); playing = nil; return }
        player.begin(rate: clip.rate)
        playing = clip.id
        player.enqueue(clip.samples, final: true) { [weak self] in self?.playing = nil }
    }

    /// Speed so far: audio produced ÷ wall time since the request.
    func speed(at now: Date) -> Double? {
        guard let started, audioSeconds > 0 else { return nil }
        return audioSeconds / (elapsed ?? now.timeIntervalSince(started))
    }

    func wallTime(at now: Date) -> Double? {
        started.map { elapsed ?? now.timeIntervalSince($0) }
    }

    static func writeWAV(_ clip: Clip, to url: URL) throws {
        if let wav = clip.wav { try wav.write(to: url); return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(clip.rate), channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: clip.rate,
                                                                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count))!
        b.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
        try file.write(from: b)
    }
}

/// Compose mode: text to sound effect or music, one clip at a time, played back as a mono mix.
@MainActor @Observable
final class ComposeModel {
    var clips: [SpeakModel.Clip] = []
    var running = false
    var error: String?
    var playing: UUID?
    private(set) var started: Date?
    private(set) var elapsed: Double?
    private var task: Task<Void, Never>?
    private let player = SpeakPlayer()

    init() { player.onError = { [weak self] in self?.error = $0 } }

    func generate(prompt: String, spec: ModelSpec, seconds: Double, seed: UInt64?, state: AppState) {
        let sound = state.sound, metrics = state.metrics
        error = nil; running = true; elapsed = nil; started = Date()
        task = Task {
            defer { running = false }
            do {
                let clip = try await sound.generate(model: spec, prompt: prompt, seconds: seconds, seed: seed)
                let took = Date().timeIntervalSince(started ?? Date())
                elapsed = took
                if !SoundEngines.mock, took > 0 { metrics.record(spec.id, .soundSpeed, clip.seconds / took) }
                clips.insert(SpeakModel.Clip(text: prompt, model: spec.id, voice: seed.map { "seed \($0)" } ?? "random seed",
                                             samples: clip.mono, rate: clip.sampleRate, wav: clip.wav), at: 0)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    func stop() { task?.cancel(); player.stop(); playing = nil }

    func toggle(_ clip: SpeakModel.Clip) {
        if playing == clip.id { player.stop(); playing = nil; return }
        player.begin(rate: clip.rate)
        playing = clip.id
        player.enqueue(clip.samples, final: true) { [weak self] in self?.playing = nil }
    }
}

struct AudioView: View {
    @Environment(AppState.self) private var state
    enum Mode: String, CaseIterable { case speak = "Speak", compose = "Compose" }

    @State private var mode = Mode.speak
    @State private var modelID = ""
    @State private var soundModelID = ""
    @State private var voice = SpeechService.pocketVoices[0]
    @State private var text = ""
    @State private var model = SpeakModel()
    @State private var composer = ComposeModel()
    @State private var length = 8.0
    @State private var randomSeed = true
    @State private var seed = "0"

    private var specs: [ModelSpec] { mode == .speak ? state.downloadedTTSSpecs : state.downloadedSoundSpecs }
    private var selection: Binding<String> { mode == .speak ? $modelID : $soundModelID }
    private var spec: ModelSpec? { Catalog.spec(selection.wrappedValue) }
    private var running: Bool { mode == .speak ? model.running : composer.running }

    var body: some View {
        Group {
            if specs.isEmpty {
                if mode == .speak {
                    ContentUnavailableView("No speech models", systemImage: "speaker.wave.2", description: Text("Download PocketTTS in Models."))
                } else {
                    ContentUnavailableView("No sound models", systemImage: "music.note",
                                           description: Text("Download Stable Audio 3 SFX or Music in Models."))
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    clipList
                    if let spec {
                        ScrollView {
                            VStack(spacing: 12) {
                                if mode == .speak { readout(spec) } else { composeReadout(spec); composePanel }
                            }
                            .padding(16).frame(maxWidth: .infinity)
                        }
                        .frame(width: 320)
                        .scrollClipDisabled()
                    }
                }
                .safeAreaInset(edge: .bottom) { bar.padding([.horizontal, .bottom], 16) }
            }
        }
        .onChange(of: state.tryRequest, initial: true) { if let s = state.takeTry(.audio) { if s.isAudioGen { mode = .compose; soundModelID = s.id } else { mode = .speak; modelID = s.id } } }
        .navigationTitle("Audio")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().disabled(running)
            }
            ToolbarItemGroup {
                if !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: selection, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                }
            }
        }
        .task { await state.refreshModels() }
        .onChange(of: state.downloadedTTSSpecs.map(\.id), initial: true) { _, ids in
            if !ids.contains(modelID) { modelID = ids.first ?? "" }
        }
        .onChange(of: state.downloadedSoundSpecs.map(\.id), initial: true) { _, ids in
            if !ids.contains(soundModelID) { soundModelID = ids.first ?? "" }
        }
        .onChange(of: running) { state.setActive(.audio, running) }
        #if DEBUG
        // `-autoSpeak "..."` speaks once after launch, and `-autoCompose "..."` generates one sound, so the readout
        // can be captured without typing.
        .task(id: spec?.id) {
            if let t = UserDefaults.standard.string(forKey: "autoSpeak"), !t.isEmpty, model.clips.isEmpty, mode == .speak, let spec {
                model.speak(text: t, spec: spec, voice: voice, state: state)
            }
        }
        .task(id: state.downloadedSoundSpecs.first?.id) {
            guard let t = UserDefaults.standard.string(forKey: "autoCompose"), !t.isEmpty, composer.clips.isEmpty, !composer.running,
                  let s = state.downloadedSoundSpecs.first else { return }
            mode = .compose; soundModelID = s.id; text = t
            composer.generate(prompt: t, spec: s, seconds: 3, seed: nil, state: state)
        }
        #endif
    }

    private func readout(_ spec: ModelSpec) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let m = model, running = m.running
            let last = m.clips.first
            BurnIn(
                name: spec.displayName, modelID: spec.id,
                readings: [
                    Reading(label: "First audio", value: m.firstAudio.map { String(format: "%.2f s", $0) }
                                ?? (running ? (m.preparing ? "loading model" : "waiting") : "–"),
                            live: running && m.firstAudio == nil),
                    m.speed(at: ctx.date).map { Reading(label: "Speed", value: String(format: "%.1f × realtime", $0), live: running) }
                        ?? Reading(label: "Speed", value: state.metrics.typical(spec.id, .ttsSpeed) ?? "–", muted: true),
                    Reading(label: "Audio length", value: m.audioSeconds > 0 ? String(format: "%.1f s", m.audioSeconds)
                                : last.map { String(format: "%.1f s", $0.seconds) } ?? "–", live: running),
                    Reading(label: "Sample rate", value: m.rate > 0 ? String(format: "%.0f kHz", Double(m.rate) / 1000) : "–"),
                    Reading(label: "Resident", value: state.resident("speech:\(spec.id)").map { gigabytes($0.bytes) } ?? "not loaded"),
                ],
                history: state.metrics.history(spec.id, .ttsSpeed), historyMetric: .ttsSpeed,
                running: running,
                api: "POST /v1/audio/speech\nmodel: \(spec.id)")
        }
    }

    private func composeReadout(_ spec: ModelSpec) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let c = composer, last = c.clips.first
            let wall = c.running ? c.started.map { ctx.date.timeIntervalSince($0) } : c.elapsed
            BurnIn(
                name: spec.displayName, modelID: spec.id,
                readings: [
                    Reading(label: "Status", value: c.running ? "generating" : "idle", live: c.running),
                    Reading(label: "Elapsed", value: wall.map { String(format: "%.1f s", $0) } ?? "–", live: c.running),
                    (c.running ? nil : last).flatMap { l in c.elapsed.map { e in
                        Reading(label: "Speed", value: String(format: "%.1f × realtime", l.seconds / max(e, 0.001)))
                    } } ?? Reading(label: "Speed", value: state.metrics.typical(spec.id, .soundSpeed) ?? "–", muted: true),
                    Reading(label: "Audio length", value: last.map { String(format: "%.1f s", $0.seconds) } ?? "–"),
                    Reading(label: "Sample rate", value: last.map { String(format: "%.1f kHz", Double($0.rate) / 1000) } ?? "–"),
                    Reading(label: "Memory", value: spec.recommendedRAMGB.map { "\($0) GB needed" } ?? "–"),
                ],
                history: state.metrics.history(spec.id, .soundSpeed), historyMetric: .soundSpeed,
                running: c.running,
                api: "POST /v1/audio/generations\nmodel: \(spec.id)")
        }
    }

    private var composePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow("Length") {
                HStack {
                    Slider(value: $length, in: 1...SoundService.maxSeconds, step: 1).frame(width: 110)
                    Text("\(Int(length)) s").font(.mono()).frame(width: 36, alignment: .trailing)
                }
            }
            PanelRow("Random seed") { Toggle("Random seed", isOn: $randomSeed).toggleStyle(.switch).labelsHidden() }
            if !randomSeed {
                PanelRow("Seed") {
                    TextField("Seed", text: $seed).font(.mono()).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 120)
                }
            }
        }
        .disabled(composer.running)
        .padding(14)
        .frame(width: 288, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder private var clipList: some View {
        let speak = mode == .speak
        let clips = speak ? model.clips : composer.clips
        let playing = speak ? model.playing : composer.playing
        let error = speak ? model.error : composer.error
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if clips.isEmpty && !running {
                    Text(speak ? "Type something below and press Return." : "Describe a sound or a piece of music and press Return.")
                        .font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(clips) { clip in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.text).font(.title3).lineLimit(2).textSelection(.enabled)
                            Text("\(clip.model) · \(clip.voice) · \(String(format: "%.1f s", clip.seconds))")
                                .font(.mono(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button(playing == clip.id ? "Stop" : "Play", systemImage: playing == clip.id ? "stop.fill" : "play.fill") {
                            if speak { model.toggle(clip) } else { composer.toggle(clip) }
                        }
                        Button("Save…", systemImage: "square.and.arrow.down") { save(clip) }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() {
        guard let spec, !running, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if mode == .speak { model.speak(text: text, spec: spec, voice: voice, state: state) } else {
            composer.generate(prompt: text, spec: spec, seconds: length, seed: randomSeed ? nil : UInt64(seed), state: state)
        }
        text = ""
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(mode == .speak ? "Text to speak" : "Describe the sound", text: $text, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).font(.title3)
                .onSubmit(submit).composerKeys()
            if mode == .speak, spec?.id == "pocket-tts" {
                ChoiceMenu(title: "Voice", selection: $voice, options: SpeechService.pocketVoices.map { ($0, $0) })
            }
            if running {
                Button("Stop", systemImage: "stop.fill") { if mode == .speak { model.stop() } else { composer.stop() } }.buttonStyle(.glass)
            } else {
                Button(mode == .speak ? "Speak" : "Generate", systemImage: mode == .speak ? "speaker.wave.2.fill" : "music.note", action: submit)
                .buttonStyle(.glassProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spec == nil)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
    }

    private func save(_ clip: SpeakModel.Clip) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = mode == .speak ? "speech.wav" : "sound.wav"
        if panel.runModal() == .OK, let url = panel.url {
            do { try SpeakModel.writeWAV(clip, to: url) } catch {
                if mode == .speak { model.error = error.localizedDescription } else { composer.error = error.localizedDescription }
            }
        }
    }
}
