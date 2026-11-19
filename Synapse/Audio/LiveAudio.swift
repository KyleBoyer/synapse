import AVFoundation
import CoreAudio

/// Mic capture (-> 24 kHz mono Int16) and 24 kHz PCM16 playback.
/// With `voiceProcessing` both run on one AVAudioEngine whose input node uses Apple's voice-processing I/O unit:
/// acoustic echo cancellation, so the assistant's own playback is not fed back into the VAD (playback must go through
/// the same engine to be the AEC reference). Without it the mic is read by an AVCaptureSession and playback has its
/// own engine: an engine drives input and output through one unit, so it cannot read a mic that has no output side
/// (a Bluetooth headset's) unless that mic is the system default.
final class LiveAudio: @unchecked Sendable {
    /// The devices a link is open on; a call that asks for the same ones reuses it.
    struct Config: Equatable {
        var input: String          // Core Audio UIDs; "" is the system default
        var output: String
        var voiceProcessing: Bool  // asked for; `echoCancel` says whether it came up
    }

    // One link to the mic and speaker for the whole app (Live's calls, Clone Voice's recording). Opening and closing
    // a Bluetooth headset blocks for seconds, so Stop only detaches the caller: the link stays open while a pane
    // that uses it is on screen and closes `idleRelease` after the last one is left, off the main thread.
    @MainActor private static var current: LiveAudio?
    @MainActor private static var holders = Set<String>()
    @MainActor private static var releaseTask: Task<Void, Never>?
    /// Device pairs whose voice-processing unit refused to start; calls there reuse the plain link.
    @MainActor private static var refusesEchoCancel = Set<String>()
    static let idleRelease: Duration = .seconds(10)

    private(set) var config: Config
    private(set) var echoCancel = false
    @MainActor private var attached = false
    private var onChunk: (@Sendable ([Int16]) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var engine: AVAudioEngine?
    private var capture: AVCaptureSession?
    private var captureReader: CaptureReader?
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    // Jitter buffer: audio is held until `prebuffer` samples arrive. Each time playback runs dry mid-stream (a model
    // producing audio slower than real time, or in bursts) the next start waits for a longer stretch, up to 1 s, so
    // gaps come rarely and whole phrases play together instead of a stutter between tiny pieces.
    private static let basePrebuffer = 3600, maxPrebuffer = 24000   // 150 ms, 1 s at 24 kHz
    private var queued: [Float] = []
    private var playing = false
    private var prebuffer = basePrebuffer
    private var scheduled = 0          // samples handed to the player and not yet played
    private var epoch = 0              // bumped by flush, so callbacks from dropped buffers are ignored

    /// Full duplex: a reply is held until its transcript reaches the end of a sentence or clause (or the model pauses),
    /// then played whole, so it is heard a phrase at a time instead of a few words between gaps. The model's text
    /// leads its voice by a few frames, so a phrase is released `phraseTail` after its punctuation arrives.
    var phraseMode: Bool {
        get { lock.withLock { phraseOn } }
        set { lock.withLock { phraseOn = newValue; held = []; releaseAt = nil; quiet = 0 } }
    }
    private static let phraseTail = 7680, phrasePause = 14400, minClause = 36000, maxPhrase = 360000   // 320 ms, 0.6 s, 1.5 s, 15 s
    private var phraseOn = false
    private var held: [Float] = []
    private var releaseAt: Int?        // held count at which the ended phrase is complete
    private var quiet = 0              // trailing near-silent samples in `held`
    private var drain: DispatchWorkItem?

    private init(_ config: Config) { self.config = config }

    @MainActor static var isOpen: Bool { current != nil }

    /// The open link on these devices (reused, or opened now, closing one on other devices), feeding this caller.
    /// Opening runs off the main thread: a Bluetooth headset takes seconds to start.
    @MainActor static func acquire(_ config: Config, onChunk: @escaping @Sendable ([Int16]) -> Void,
                                   onLevel: @escaping @Sendable (Float) -> Void) async throws -> LiveAudio {
        releaseTask?.cancel(); releaseTask = nil
        var config = config
        let pair = config.input + "|" + config.output
        if refusesEchoCancel.contains(pair) { config.voiceProcessing = false }
        if let c = current, c.config != config { current = nil; c.close() }
        var link: LiveAudio
        if let c = current {
            link = c
        } else {
            let l = LiveAudio(config)
            try await Task.detached(priority: .userInitiated) { try l.open() }.value
            if config.voiceProcessing && !l.echoCancel { refusesEchoCancel.insert(pair); l.config.voiceProcessing = false }
            link = l
            // Another caller opened a link while this one was opening: keep one.
            if let other = current {
                if other.config == l.config { l.close(); link = other } else { current = nil; other.close() }
            }
        }
        current = link
        link.flush()
        link.lock.withLock { link.onChunk = onChunk; link.onLevel = onLevel }
        link.attached = true
        return link
    }

    /// The call is over: stop feeding it and drop its queued audio. The devices stay open (see `current`).
    @MainActor func release() {
        lock.withLock { onChunk = nil; onLevel = nil }
        phraseMode = false
        flush()
        attached = false
        Self.scheduleRelease()
    }

    /// While a pane that uses the mic is on screen (`pane` names it), an idle link stays open.
    @MainActor static func hold(_ pane: String, _ on: Bool) {
        if on { holders.insert(pane); releaseTask?.cancel(); releaseTask = nil } else { holders.remove(pane); scheduleRelease() }
    }

    @MainActor private static func scheduleRelease() {
        guard holders.isEmpty, let c = current, !c.attached else { return }
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: idleRelease)
            guard !Task.isCancelled, current === c, !c.attached, holders.isEmpty else { return }
            current = nil
            c.close()
        }
    }

    /// Opens the devices. Echo cancellation needs mic and playback on one voice-processing engine; it refuses some
    /// devices (error -10875, for example a Bluetooth headset's 8 kHz mic), and then the link runs without it.
    private func open() throws {
        let deliver: @Sendable ([Int16]) -> Void = { [weak self] samples in
            guard let self, !samples.isEmpty else { return }
            let (chunk, level) = self.lock.withLock { (self.onChunk, self.onLevel) }
            guard let chunk else { return }
            let rms = (samples.reduce(0) { $0 + Float($1) * Float($1) } / Float(samples.count)).squareRoot() / 32768
            level?(min(1, rms * 4))
            chunk(samples)
        }
        let output = AudioDevices.device(uid: config.output, input: false)
        if config.voiceProcessing {
            let e = AVAudioEngine()
            do {
                try e.inputNode.setVoiceProcessingEnabled(true)
                if let id = AudioDevices.device(uid: config.input, input: true) { try e.inputNode.auAudioUnit.setDeviceID(id) }
                try tap(e.inputNode, deliver)
                try startPlayback(on: e, output)
                engine = e
                echoCancel = true
                return
            } catch {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
                if player.engine === e { e.detach(player) }
                try? e.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        try startCapture(config.input, deliver)
        let e = AVAudioEngine()
        do { try startPlayback(on: e, output) } catch { close(); throw error }
        engine = e
    }

    private func startPlayback(on e: AVAudioEngine, _ device: AudioDeviceID?) throws {
        if let device { try e.outputNode.auAudioUnit.setDeviceID(device) }
        e.attach(player)
        e.connect(player, to: e.mainMixerNode, format: outFormat)
        e.prepare()
        try e.start()
        player.play()
    }

    private func tap(_ input: AVAudioInputNode, _ deliver: @escaping @Sendable ([Int16]) -> Void) throws {
        let inFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "Synapse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format."])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 24000 / inFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
            deliver(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength))))
        }
    }

    /// Reads the mic (a Core Audio UID is also its AVCaptureDevice unique ID), converted to 24 kHz mono Int16.
    private func startCapture(_ uid: String, _ deliver: @escaping @Sendable ([Int16]) -> Void) throws {
        guard let device = (uid.isEmpty ? nil : AVCaptureDevice(uniqueID: uid)) ?? AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "Synapse", code: 2, userInfo: [NSLocalizedDescriptionKey: "No microphone is connected."])
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                AVLinearPCMIsNonInterleaved: false]
        let reader = CaptureReader(deliver)
        output.setSampleBufferDelegate(reader, queue: reader.queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "Synapse", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(device.localizedName) can't be read."])
        }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        capture = session
        captureReader = reader
    }

    func play(pcm16: Data) {
        let floats = pcm16.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
        lock.lock(); defer { lock.unlock() }
        if phraseOn { hold(floats); return }
        queued += floats
        if !playing && queued.count < prebuffer { return }
        playing = true
        schedule(queued); queued = []
    }

    /// The transcript reached the end of a sentence (`strong`) or a clause (a comma): play that phrase once its last
    /// words have arrived. A comma counts only after a long stretch, so short clauses stay with their sentence.
    func phraseEnded(strong: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard phraseOn, strong || held.count >= Self.minClause else { return }
        releaseAt = held.count + Self.phraseTail
    }

    /// Phrase mode, under `lock`.
    private func hold(_ f: [Float]) {
        let rms = f.isEmpty ? 0 : (f.reduce(0) { $0 + $1 * $1 } / Float(f.count)).squareRoot()
        let silent = rms < 0.005
        if held.isEmpty && silent { schedule(f); return }   // idle: silence passes straight through
        held += f
        quiet = silent ? quiet + f.count : 0
        if let r = releaseAt, held.count >= r { releaseHeld(); return }
        if quiet >= Self.phrasePause || held.count >= Self.maxPhrase { releaseHeld(); return }
        // A model that stops sending audio when it stops talking (VoiceChat) ends its last phrase by going quiet.
        drain?.cancel()
        let e = epoch
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock { if self.epoch == e, self.phraseOn, !self.held.isEmpty { self.releaseHeld() } }
        }
        drain = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1, execute: item)
    }

    #if DEBUG
    /// Lengths (ms) of the phrases released so far, for -jitterTest.
    private(set) var releasedMS: [Int] = []
    #endif

    private func releaseHeld() {
        #if DEBUG
        releasedMS.append(held.count * 1000 / 24000)
        #endif
        drain?.cancel(); drain = nil
        schedule(held)
        held = []; releaseAt = nil; quiet = 0
    }

    /// Barge-in (or a new reply): drop everything scheduled or buffered, and start again from the short buffer.
    func flush() {
        lock.withLock {
            queued = []; playing = false; scheduled = 0; epoch += 1; prebuffer = Self.basePrebuffer
            held = []; releaseAt = nil; quiet = 0; drain?.cancel(); drain = nil
        }
        // Outside the lock: stopping calls the dropped buffers' completion handlers, which take it.
        player.stop(); player.play()
    }

    /// The buffer length a reply needs before it starts, after any growth from running dry (for checks).
    var currentPrebuffer: Int { lock.withLock { prebuffer } }

    private func schedule(_ s: [Float]) {
        guard !s.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(s.count)) else { return }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        scheduled += s.count
        let n = s.count, e = epoch
        player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { [weak self] _ in self?.played(n, epoch: e) }
    }

    private func played(_ n: Int, epoch e: Int) {
        lock.lock(); defer { lock.unlock() }
        guard e == epoch else { return }
        scheduled -= n
        guard scheduled <= 0, playing, queued.isEmpty else { return }
        playing = false   // ran dry: buffer a longer stretch before playing again
        prebuffer = min(prebuffer * 3 / 2, Self.maxPrebuffer)
    }

    /// Closes the devices on a background queue: stopping a Bluetooth headset's capture and output blocks for seconds.
    private func close() {
        let capture = capture, engine = engine, player = player, echoCancel = echoCancel
        self.capture = nil; self.engine = nil; captureReader = nil
        nonisolated(unsafe) let parts = (capture, engine, player)
        DispatchQueue.global(qos: .utility).async {
            let (capture, engine, player) = parts
            capture?.stopRunning()
            player.stop()
            if let engine {
                if echoCancel { engine.inputNode.removeTap(onBus: 0) }
                engine.stop()
                if echoCancel { try? engine.inputNode.setVoiceProcessingEnabled(false) }
            }
        }
    }
}

/// Hands each captured buffer's Int16 samples on.
private final class CaptureReader: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Synapse.LiveAudio.capture")
    private let deliver: @Sendable ([Int16]) -> Void
    #if DEBUG
    private var loggedFormat = false
    #endif
    init(_ deliver: @escaping @Sendable ([Int16]) -> Void) { self.deliver = deliver }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        #if DEBUG
        if !loggedFormat, let f = sampleBuffer.formatDescription?.audioStreamBasicDescription {
            loggedFormat = true
            fputs("LiveAudio capture format: \(f)\n", stderr)
        }
        #endif
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buffer = list.first, let data = buffer.mData else { return }
            deliver(Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self),
                                              count: Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size)))
        }
    }
}
