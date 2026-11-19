import AVFoundation
import CoreAudio

/// Mic capture (-> 24 kHz mono Int16) and 24 kHz PCM16 playback.
/// With `voiceProcessing` both run on one AVAudioEngine whose input node uses Apple's voice-processing I/O unit:
/// acoustic echo cancellation, so the assistant's own playback is not fed back into the VAD (playback must go through
/// the same engine to be the AEC reference). Without it the mic is read by an AVCaptureSession and playback has its
/// own engine: an engine drives input and output through one unit, so it cannot read a mic that has no output side
/// (a Bluetooth headset's) unless that mic is the system default.
final class LiveAudio: @unchecked Sendable {
    nonisolated(unsafe) private static weak var claim: LiveAudio?
    private var engine: AVAudioEngine?
    private var capture: AVCaptureSession?
    private var captureReader: CaptureReader?
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var queued: [Float] = []   // jitter buffer: held until `prebuffer` samples arrive
    private var playing = false
    private let prebuffer = 3600       // 150 ms

    /// Starts on the devices with these Core Audio UIDs ("" is the system default). Returns whether echo
    /// cancellation is on: the voice-processing unit refuses some devices (error -10875, for example a Bluetooth
    /// headset's 8 kHz mic), and then the session runs without it.
    func start(inputUID: String, outputUID: String, voiceProcessing: Bool,
               onChunk: @escaping @Sendable ([Int16]) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws -> Bool {
        // One claim on the mic and speaker for the whole app: a session left running (a pane kept alive, a call that
        // ended on its own) is stopped before this one opens the devices.
        if let other = Self.claim, other !== self { other.stop() }
        Self.claim = self
        let deliver: @Sendable ([Int16]) -> Void = { samples in
            guard !samples.isEmpty else { return }
            let rms = (samples.reduce(0) { $0 + Float($1) * Float($1) } / Float(samples.count)).squareRoot() / 32768
            onLevel(min(1, rms * 4))
            onChunk(samples)
        }
        let output = AudioDevices.device(uid: outputUID, input: false)
        if voiceProcessing {
            let e = AVAudioEngine()
            do {
                try e.inputNode.setVoiceProcessingEnabled(true)
                if let id = AudioDevices.device(uid: inputUID, input: true) { try e.inputNode.auAudioUnit.setDeviceID(id) }
                try tap(e.inputNode, deliver)
                try startPlayback(on: e, output)
                engine = e
                return true
            } catch {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
                if player.engine === e { e.detach(player) }
                try? e.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        try startCapture(inputUID, deliver)
        let e = AVAudioEngine()
        do { try startPlayback(on: e, output) } catch { stop(); throw error }
        engine = e
        return false
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
        queued += floats
        if !playing && queued.count < prebuffer { return }
        playing = true
        schedule(queued); queued = []
    }

    /// Barge-in: drop everything scheduled or buffered.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        queued = []; playing = false
        player.stop(); player.play()
    }

    private func schedule(_ s: [Float]) {
        guard !s.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(s.count)) else { return }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        player.scheduleBuffer(b, completionHandler: nil)
    }

    func stop() {
        capture?.stopRunning()
        capture = nil
        captureReader = nil
        player.stop()
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
            try? e.inputNode.setVoiceProcessingEnabled(false)
        }
        engine = nil
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
