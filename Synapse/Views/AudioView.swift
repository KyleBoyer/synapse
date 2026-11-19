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
    /// The output device's Core Audio UID; nil or "" plays on the system default.
    var deviceUID: String?
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
        guard status == noErr, let q else { onError?("Could not open the audio output (\(status))."); return }
        if let uid = deviceUID, !uid.isEmpty {
            var cf = uid as CFString
            AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cf, UInt32(MemoryLayout<CFString>.size))
        }
        queue = q
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
        // Disposing waits for the device to stop, which takes about 15 s on a Bluetooth headset; never on the main thread.
        if let queue {
            self.queue = nil
            nonisolated(unsafe) let q = queue
            DispatchQueue.global(qos: .userInitiated).async { AudioQueueDispose(q, true) }
        }
    }
}

@MainActor @Observable
final class SpeakModel {
    struct Clip: Identifiable {
        var id = UUID()
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
    /// The text being spoken, shown with progress until its clip arrives.
    private(set) var pending: String?
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
        started = nil; pending = text
        task = Task {
            preparing = state.resident("speech:\(spec.id)") == nil
            defer { running = false; preparing = false; pending = nil }
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

    /// A saved clip read back: mono samples for playback, and the file itself so Save… keeps stereo.
    static func readWAV(_ url: URL) -> (samples: [Float], rate: Int, wav: Data)? {
        guard let f = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil, let ch = b.floatChannelData, let wav = try? Data(contentsOf: url) else { return nil }
        let n = Int(b.frameLength), c = Int(b.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<c { for j in 0..<n { mono[j] += ch[i][j] / Float(c) } }
        return (mono, Int(f.processingFormat.sampleRate), wav)
    }
}

/// Compose mode: text to sound effect or music, one clip at a time, played back as a mono mix.
@MainActor @Observable
final class ComposeModel {
    var clips: [SpeakModel.Clip] = []
    var running = false
    var error: String?
    var playing: UUID?
    /// What is being made (the prompt, or the recording's name), shown with progress until its clips arrive.
    private(set) var pending: String?
    private(set) var started: Date?
    private(set) var elapsed: Double?
    private var task: Task<Void, Never>?
    private let player = SpeakPlayer()

    init() { player.onError = { [weak self] in self?.error = $0 } }

    func generate(prompt: String, lyrics: String? = nil, spec: ModelSpec, seconds: Double, seed: UInt64?, state: AppState) {
        let sound = state.sound, metrics = state.metrics
        error = nil; running = true; elapsed = nil; started = Date(); pending = prompt
        task = Task {
            defer { running = false; pending = nil }
            do {
                let clip = try await sound.generate(model: spec, prompt: prompt, lyrics: lyrics, seconds: seconds, seed: seed)
                let took = Date().timeIntervalSince(started ?? Date())
                elapsed = took
                if !SoundEngines.mock, took > 0 { metrics.record(spec.id, .soundSpeed, clip.seconds / took) }
                clips.insert(SpeakModel.Clip(text: prompt, model: spec.id, voice: seed.map { "seed \($0)" } ?? "random seed",
                                             samples: clip.mono, rate: clip.sampleRate, wav: clip.wav), at: 0)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Clean Up mode: a recording through a noise-removal or separation model; each output track becomes a clip.
    func edit(input: URL, prompt: String?, spec: ModelSpec, state: AppState) {
        let sound = state.sound
        error = nil; running = true; elapsed = nil; started = Date(); pending = input.lastPathComponent
        task = Task {
            defer { running = false; pending = nil }
            do {
                let tracks = try await sound.edit(model: spec, input: input, prompt: prompt)
                elapsed = Date().timeIntervalSince(started ?? Date())
                let what = prompt ?? (SoundService.editTask(spec) == .enhance ? "noise removed" : "separated")
                for t in tracks.reversed() {
                    let title = t.name == "audio" ? input.lastPathComponent : "\(input.lastPathComponent): \(t.name.replacingOccurrences(of: "_", with: " "))"
                    clips.insert(SpeakModel.Clip(text: title,
                                                 model: spec.id, voice: what, samples: t.clip.mono, rate: t.clip.sampleRate, wav: t.clip.wav), at: 0)
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Clean Up with a converting model: the recording re-spoken in a cloned voice.
    func convert(input: URL, voice: CustomVoice, spec: ModelSpec, state: AppState) {
        let speech = state.speech
        error = nil; running = true; elapsed = nil; started = Date(); pending = "\(input.lastPathComponent) as \(voice.name)"
        task = Task {
            defer { running = false; pending = nil }
            do {
                let (rate, pcm) = try await speech.convert(model: spec, source: input, voice: voice.id)
                var samples: [Float] = []
                for try await f in pcm { samples += f }
                elapsed = Date().timeIntervalSince(started ?? Date())
                clips.insert(SpeakModel.Clip(text: "\(input.lastPathComponent) as \(voice.name)", model: spec.id, voice: voice.id,
                                             samples: samples, rate: rate), at: 0)
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
    #if DEBUG
    @MainActor static var autoNextDone = false
    #endif
    @Environment(AppState.self) private var state
    @Environment(\.paneShown) private var paneShown
    /// Sound & Music (a prompt becomes a clip) leads; Speech reads text aloud; Clean Up works on a recording.
    enum Mode: String, CaseIterable { case compose = "Sound & Music", speak = "Speech", edit = "Clean Up" }

    @State private var mode = Mode.compose
    @State private var modelID = ""
    @State private var soundModelID = ""
    @State private var voice = SpeechService.pocketVoices[0]
    @State private var customVoices: [CustomVoice] = []
    @State private var cloning = false
    @State private var deleting: CustomVoice?
    @State private var text = ""
    @State private var lyrics = ""
    @State private var model = SpeakModel()
    @State private var composer = ComposeModel()
    @State private var editor = ComposeModel()
    /// Clips already in history (saved here or loaded from it), so each is written once.
    @State private var savedClips = Set<UUID>()
    @State private var editModelID = ""
    @State private var editInput: URL?
    @State private var length = 8.0
    @State private var randomSeed = true
    @State private var seed = "0"

    private var specs: [ModelSpec] {
        switch mode {
        case .speak: state.downloadedTTSSpecs
        case .compose: state.downloadedSoundSpecs
        // Voice conversion sits with the other audio-to-audio models.
        case .edit: state.downloadedEditSpecs + state.downloadedTTSSpecs.filter { SpeechService.converters.contains($0.id) }
        }
    }
    private var selection: Binding<String> {
        switch mode { case .speak: $modelID; case .compose: $soundModelID; case .edit: $editModelID }
    }
    private var spec: ModelSpec? { Catalog.spec(selection.wrappedValue) }
    /// Compose and Clean Up share one clip model shape; each mode keeps its own clips.
    private var sounds: ComposeModel { mode == .edit ? editor : composer }
    private var running: Bool { mode == .speak ? model.running : sounds.running }
    private var needsPrompt: Bool { mode == .edit && spec.map(SoundService.needsPrompt) == true }
    private var converts: Bool { mode == .edit && spec.map { SpeechService.converters.contains($0.id) } == true }
    @State private var convertVoice = ""

    /// The right column for the current mode (its own builder: inline, it is too much for Swift 6.2's type checker).
    @ViewBuilder private func sidePanel(_ spec: ModelSpec) -> some View {
        switch mode {
        case .speak:
            readout(spec)
            if SpeechService.support(spec.id).clones { voicesPanel }
        case .edit: editReadout(spec)
        case .compose: composeReadout(spec); composePanel
        }
    }

    var body: some View {
        observed
            .onChange(of: state.handoff, initial: true) { takeHandoff() }
    }

    /// A result sent here from another pane: a recording to clean up, or text to speak or turn into a sound.
    private func takeHandoff() {
        switch state.handoff {
        case .cleanUp(let url): state.handoff = nil; mode = .edit; editInput = url
        case .prompt(let t, .speech): state.handoff = nil; mode = .speak; text = t
        case .prompt(let t, .sound): state.handoff = nil; mode = .compose; text = t
        default: break
        }
    }

    private var content: some View {
        Group {
            if specs.isEmpty {
                if mode == .speak {
                    ContentUnavailableView("No speech models", systemImage: "speaker.wave.2", description: Text("Download PocketTTS in Models."))
                } else if mode == .edit {
                    ContentUnavailableView("No cleanup models", systemImage: "waveform.badge.magnifyingglass",
                                           description: Text("Download DeepFilterNet 3 to remove noise, or SAM-Audio small to pull one sound out of a recording, in Models."))
                } else {
                    ContentUnavailableView("No sound models", systemImage: "music.note",
                                           description: Text("Download Stable Audio 3 SFX or Music in Models."))
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    clipList
                    if let spec {
                        ScrollView {
                            VStack(spacing: 12) { sidePanel(spec) }
                                .padding(16).frame(maxWidth: .infinity)
                        }
                        .frame(width: 320)
                        .scrollClipDisabled()
                    }
                }
                .safeAreaInset(edge: .bottom) { bar.padding([.horizontal, .bottom], 16) }
            }
        }
        .onChange(of: state.tryRequest, initial: true) {
            guard let s = state.takeTry(.audio) else { return }
            if s.isAudioGen { mode = .compose; soundModelID = s.id } else if s.isAudioEdit { mode = .edit; editModelID = s.id } else { mode = .speak; modelID = s.id }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard mode == .edit else { return false }
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in editInput = url } } }
            return true
        }
        .toolbar { if paneShown {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().disabled(running)
            }
            ToolbarItemGroup {
                if !specs.isEmpty {
                    ChoiceMenu(title: "Model", selection: selection, options: specs.map { ($0.id, $0.displayName) }, detail: { $0 })
                }
                ClearHistoryButton(noun: mode == .speak ? "speech clip" : mode == .edit ? "cleaned-up clip" : "sound") {
                    state.clearHistory(historyKind)
                    switch mode { case .speak: model.clips = []; case .edit: editor.clips = []; default: composer.clips = [] }
                }
            }
        } }
    }

    /// Lifecycle and data hooks, split from `content` so Swift 6.2's type checker handles each half.
    private var observed: some View {
        content
        .task { await state.refreshModels(); customVoices = await state.speech.voices.voices() }
        .task(id: state.historyRevision) { await loadHistory() }
        #if DEBUG
        // `-autoNext cleanup` sends the first Speak clip to Clean Up, for checks.
        .onChange(of: model.clips.first?.id) {
            guard UserDefaults.standard.string(forKey: "autoNext") == "cleanup", !Self.autoNextDone, let c = model.clips.first else { return }
            Self.autoNextDone = true
            cleanUp(c)
        }
        #endif
        .onChange(of: model.clips.map(\.id)) { saveNew(model.clips, kind: .speech) }
        .onChange(of: composer.clips.map(\.id)) { saveNew(composer.clips, kind: .sound) }
        .onChange(of: editor.clips.map(\.id)) { saveNew(editor.clips, kind: .audioEdit) }
        .sheet(isPresented: $cloning) {
            CloneVoiceSheet { v in
                customVoices.append(v); voice = v.id
                #if DEBUG
                if let t = UserDefaults.standard.string(forKey: "autoSpeak"), !t.isEmpty, let spec { model.speak(text: t, spec: spec, voice: v.id, state: state) }
                #endif
            }
            .environment(state)
        }
        .confirmationDialog("Delete the voice \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { v in
            Button("Delete Voice", role: .destructive) {
                Task {
                    _ = await state.speech.voices.deleteVoice(v.id)
                    customVoices.removeAll { $0.id == v.id }
                    if voice == v.id { voice = SpeechService.pocketVoices[0] }
                }
            }
        } message: { _ in Text("Clips already made keep their audio. API clients using this voice id will get an error.") }
        .onChange(of: state.downloadedTTSSpecs.map(\.id), initial: true) { _, ids in
            if !ids.contains(modelID) { modelID = ids.first ?? "" }
        }
        .onChange(of: state.downloadedSoundSpecs.map(\.id), initial: true) { _, ids in
            if !ids.contains(soundModelID) { soundModelID = ids.first ?? "" }
        }
        .onChange(of: state.downloadedEditSpecs.map(\.id), initial: true) { _, _ in
            let ids = (mode == .edit ? specs : state.downloadedEditSpecs).map(\.id)
            if !ids.contains(editModelID) { editModelID = ids.first ?? "" }
        }
        .onChange(of: running) { state.setActive(.audio, running) }
        // Keep the voice valid for the chosen model (a cloned voice survives a switch between cloning models).
        .onChange(of: voiceOptions.map(\.0), initial: true) { _, ids in
            if !ids.contains(voice) { voice = ids.first ?? voice }
        }
        #if DEBUG
        // `-autoSpeak "..."` speaks once after launch, and `-autoCompose "..."` generates one sound, so the readout
        // can be captured without typing.
        .task(id: spec?.id) {
            // `-cloneSample <path>` opens the clone sheet with that clip (see CloneVoiceSheet).
            if UserDefaults.standard.string(forKey: "cloneSample") != nil, spec.map({ SpeechService.support($0.id).clones }) == true {
                cloning = true; return
            }
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
        // `-autoEdit <path>` runs Clean Up on that file (with `-autoEditModel <id>` and `-autoEditPrompt "..."`).
        .task(id: state.downloadedEditSpecs.first?.id) {
            guard let path = UserDefaults.standard.string(forKey: "autoEdit"), editor.clips.isEmpty, !editor.running,
                  let s = UserDefaults.standard.string(forKey: "autoEditModel").flatMap(Catalog.spec) ?? state.downloadedEditSpecs.first,
                  state.downloadedEditSpecs.contains(s) || state.downloadedTTSSpecs.contains(s) else { return }
            customVoices = await state.speech.voices.voices()
            mode = .edit; editModelID = s.id; editInput = URL(fileURLWithPath: path)
            text = UserDefaults.standard.string(forKey: "autoEditPrompt") ?? ""
            submit()
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
                    Reading(label: "Resident", value: state.resident("speech:\(spec.id)").map { $0.memory } ?? "not loaded"),
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

    private func editReadout(_ spec: ModelSpec) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let c = editor, last = c.clips.first
            let wall = c.running ? c.started.map { ctx.date.timeIntervalSince($0) } : c.elapsed
            let separate = SoundService.editTask(spec) == .separate, converting = SpeechService.converters.contains(spec.id)
            BurnIn(
                name: spec.displayName, modelID: spec.id,
                readings: [
                    Reading(label: "Status", value: c.running ? (converting ? "converting" : separate ? "separating" : "cleaning") : "idle", live: c.running),
                    Reading(label: "Elapsed", value: wall.map { String(format: "%.1f s", $0) } ?? "–", live: c.running),
                    Reading(label: "Audio length", value: last.map { String(format: "%.1f s", $0.seconds) } ?? "–"),
                    Reading(label: "Sample rate", value: last.map { String(format: "%.1f kHz", Double($0.rate) / 1000) } ?? "–"),
                    Reading(label: "Memory", value: spec.recommendedRAMGB.map { "\($0) GB needed" } ?? "small"),
                ],
                history: [], historyMetric: nil,
                running: c.running,
                api: "POST /v1/audio/\(converting ? "convert" : separate ? "separate" : "enhance")\nmodel: \(spec.id)")
        }
    }

    private func voiceName(_ id: String) -> String { customVoices.first { $0.id == id }?.name ?? id }

    /// The voices the chosen model speaks: its stock voices, then cloned voices if it clones. Empty for a model that
    /// speaks only cloned voices (Qwen3-TTS) until one is made.
    private var voiceOptions: [(String, String)] {
        guard let spec, mode == .speak else { return [] }
        let s = SpeechService.support(spec.id)
        let stock = s.stock == ["default"] ? [("default", "Default voice")] : s.stock.map { ($0, $0) }
        return stock + (s.clones ? customVoices.map { ($0.id, $0.name) } : [])
    }

    /// Voices cloned from a clip; each id is what API clients send as `voice`.
    private var voicesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom voices").font(.headline)
                Spacer()
                Button("Clone Voice…", systemImage: "person.wave.2") { cloning = true }.buttonStyle(.glass).disabled(model.running)
            }
            if customVoices.isEmpty {
                Text("Clone a voice from 5 to 10 seconds of one person speaking.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(customVoices) { v in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.name)
                        Text(v.id).font(.mono(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f s", v.seconds)).font(.mono(.caption)).foregroundStyle(.secondary)
                    Button("Delete \(v.name)", systemImage: "trash") { deleting = v }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .frame(width: 288, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
            if let spec, SoundService.takesLyrics(spec) {
                // Sung by the model; the prompt below describes the style. Section tags like [verse] go on their own lines.
                TextField("Lyrics (optional): [verse] … [chorus] …", text: $lyrics, axis: .vertical)
                    .lineLimit(3...8).textFieldStyle(.roundedBorder)
            }
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
        let clips = speak ? model.clips : sounds.clips
        let playing = speak ? model.playing : sounds.playing
        let error = speak ? model.error : sounds.error
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if clips.isEmpty && !running {
                    if speak, voiceOptions.isEmpty, let spec {
                        Text("\(spec.displayName) speaks only in cloned voices. Clone one with Clone Voice… to start.")
                            .font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                    } else {
                        Text(speak ? "Type something below and press Return."
                             : mode == .edit ? "Choose or drop a recording, then press Clean Up."
                             : "Describe a sound or a piece of music and press Return.")
                            .font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                    }
                }
                if let pending = speak ? model.pending : sounds.pending {
                    pendingRow(pending, speak: speak)
                }
                ForEach(clips) { clip in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.text).font(.title3).lineLimit(2).textSelection(.enabled)
                            Text("\(clip.model) · \(voiceName(clip.voice)) · \(String(format: "%.1f s", clip.seconds))")
                                .font(.mono(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button(playing == clip.id ? "Stop" : "Play", systemImage: playing == clip.id ? "stop.fill" : "play.fill") {
                            if speak { model.toggle(clip) } else { sounds.toggle(clip) }
                        }
                        // Speech and sounds carry the text they came from; a cleaned-up recording has none of its own.
                        SendToMenu(item: .audio(file: { clipFile(clip) }, text: mode == .edit ? nil : clip.text))
                        Button("Clean Up", systemImage: "wand.and.sparkles") { cleanUp(clip) }
                            .disabled(state.downloadedEditSpecs.isEmpty || running)
                            .help(state.downloadedEditSpecs.isEmpty ? "Download a Clean Up model (DeepFilterNet, SAM-Audio…) in Models"
                                  : "Clean Up: remove noise, separate sounds or re-voice this clip")
                        Button("Save…", systemImage: "square.and.arrow.down") { save(clip) }
                        DeleteItemMenu(noun: "clip") { delete(clip) }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The clip being made: its text and a live label with the time so far.
    private func pendingRow(_ text: String, speak: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let since = (speak ? model.started : sounds.started).map { ctx.date.timeIntervalSince($0) }
            let verb = speak ? (model.preparing ? "Loading model" : "Speaking")
                : mode == .edit ? (converts ? "Converting" : "Cleaning up") : "Generating"
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.title3).lineLimit(2).foregroundStyle(.secondary)
                LiveProgress(label: verb + (since.map { String(format: " · %.0f s", $0) } ?? "…"))
            }
        }
    }

    private func submit() {
        if mode == .edit {
            guard let spec, let editInput, !running, !needsPrompt || !trimmed.isEmpty else { return }
            if converts {
                guard let v = customVoices.first(where: { $0.id == convertVoice }) ?? customVoices.first else { return }
                editor.convert(input: editInput, voice: v, spec: spec, state: state)
            } else {
                editor.edit(input: editInput, prompt: needsPrompt ? trimmed : nil, spec: spec, state: state)
            }
            return
        }
        guard let spec, !running, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if mode == .speak {
            guard voiceOptions.contains(where: { $0.0 == voice }) else { return }
            model.speak(text: text, spec: spec, voice: voice, state: state)
        } else {
            composer.generate(prompt: text, lyrics: SoundService.takesLyrics(spec) && !lyrics.isEmpty ? lyrics : nil, spec: spec,
                              seconds: length, seed: randomSeed ? nil : UInt64(seed), state: state)
        }
        text = ""
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if mode == .edit {
                Button(editInput == nil ? "Choose Recording…" : "Change…", systemImage: "waveform") { chooseRecording() }.buttonStyle(.glass)
                if let editInput {
                    Text(editInput.lastPathComponent).lineLimit(1).truncationMode(.middle).font(.title3)
                }
                if needsPrompt {
                    TextField("Sound to keep, like speech or dog barking", text: $text).textFieldStyle(.plain).font(.title3)
                        .onSubmit(submit)
                } else {
                    Spacer(minLength: 0)
                }
                if converts {
                    if customVoices.isEmpty {
                        Text("Clone a voice in Speak first").foregroundStyle(.secondary)
                    } else {
                        ChoiceMenu(title: "Voice", selection: Binding(get: { customVoices.contains { $0.id == convertVoice } ? convertVoice : customVoices[0].id },
                                                                      set: { convertVoice = $0 }),
                                   options: customVoices.map { ($0.id, $0.name) })
                    }
                }
            } else {
                TextField(mode == .speak ? "Text to speak" : "Describe the sound", text: $text, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).font(.title3)
                    .onSubmit(submit).composerKeys()
            }
            if mode == .speak, voiceOptions.count > 1 {
                ChoiceMenu(title: "Voice", selection: $voice, options: voiceOptions)
            }
            if running {
                Button("Stop", systemImage: "stop.fill") { if mode == .speak { model.stop() } else { sounds.stop() } }.buttonStyle(.glass)
            } else if mode == .edit {
                Button(converts ? "Convert" : spec.map { SoundService.editTask($0) == .separate } == true ? "Separate" : "Clean Up",
                       systemImage: converts ? "person.wave.2" : "wand.and.sparkles", action: submit)
                    .buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(spec == nil || editInput == nil || (needsPrompt && trimmed.isEmpty) || (converts && customVoices.isEmpty))
            } else {
                Button(mode == .speak ? "Speak" : "Generate", systemImage: mode == .speak ? "speaker.wave.2.fill" : "music.note", action: submit)
                .buttonStyle(.glassProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spec == nil || (mode == .speak && voiceOptions.isEmpty))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
        // Clone Voice records here, so an open mic link stays open while Audio is on screen.
        .onChange(of: paneShown, initial: true) { LiveAudio.hold("audio", paneShown) }
    }

    private func chooseRecording() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie]
        if p.runModal() == .OK, let url = p.url { editInput = url }
    }

    private var historyKind: HistoryKind { mode == .speak ? .speech : mode == .edit ? .audioEdit : .sound }
    private struct SavedClip: Codable { var voice: String }

    /// Writes clips not yet in history; new clips arrive from three places (Speak, Compose, Clean Up).
    private func saveNew(_ clips: [SpeakModel.Clip], kind: HistoryKind) {
        for c in clips where !savedClips.contains(c.id) {
            savedClips.insert(c.id)
            let tmp = FileManager.default.temporaryDirectory.appending(path: "\(c.id).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? SpeakModel.writeWAV(c, to: tmp)) != nil, let wav = try? Data(contentsOf: tmp) else { continue }
            state.saveHistory(HistoryItem(id: c.id, kind: kind, title: c.text, model: c.model,
                                          payload: (try? JSONEncoder().encode(SavedClip(voice: c.voice))) ?? Data()),
                              files: ["clip.wav": wav])
        }
    }

    // shortcut: the newest 50 clips of each mode load (their samples are held in memory); page in more if needed.
    private func loadHistory() async {
        guard state.savesHistory else { return }
        func load(_ kind: HistoryKind) async -> [SpeakModel.Clip] {
            var out: [SpeakModel.Clip] = []
            for item in await state.history.list(kind).prefix(50) {
                guard let audio = SpeakModel.readWAV(await state.history.url(item, "clip.wav")) else { continue }
                out.append(.init(id: item.id, text: item.title, model: item.model, voice: item.decode(SavedClip.self)?.voice ?? "",
                                 samples: audio.samples, rate: audio.rate, wav: audio.wav))
            }
            return out
        }
        let speech = await load(.speech), sound = await load(.sound), edits = await load(.audioEdit)
        savedClips.formUnion((speech + sound + edits).map(\.id))
        model.clips = speech; composer.clips = sound; editor.clips = edits
    }

    /// Sends a clip to Clean Up as its input recording, written out as a WAV named after the clip.
    private func cleanUp(_ clip: SpeakModel.Clip) {
        guard let url = clipFile(clip) else { return }
        mode = .edit
        editInput = url
    }

    /// The clip as a WAV named after it, for panes that take files.
    private func clipFile(_ clip: SpeakModel.Clip) -> URL? {
        let name = clip.text.prefix(40).map { "/:\\".contains($0) ? "-" : $0 }
        let url = FileManager.default.temporaryDirectory.appending(path: "Synapse-clips", directoryHint: .isDirectory)
            .appending(path: "\(String(name).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))).wav")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try SpeakModel.writeWAV(clip, to: url)
            return url
        } catch {
            sounds.error = error.localizedDescription
            return nil
        }
    }

    private func delete(_ clip: SpeakModel.Clip) {
        model.clips.removeAll { $0.id == clip.id }; composer.clips.removeAll { $0.id == clip.id }; editor.clips.removeAll { $0.id == clip.id }
        state.deleteHistory([clip.id], kind: historyKind)
    }

    private func save(_ clip: SpeakModel.Clip) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = mode == .speak ? "speech.wav" : "sound.wav"
        if panel.runModal() == .OK, let url = panel.url {
            do { try SpeakModel.writeWAV(clip, to: url) } catch {
                if mode == .speak { model.error = error.localizedDescription } else { sounds.error = error.localizedDescription }
            }
        }
    }
}
