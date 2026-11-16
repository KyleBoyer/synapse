import AVFoundation

/// Mic capture (-> 24 kHz mono Int16) and 24 kHz PCM16 playback on one AVAudioEngine.
/// With `voiceProcessing` the input node uses Apple's voice-processing I/O unit, which provides acoustic echo
/// cancellation so the assistant's own playback is not fed back into the VAD. Playback goes through the same
/// engine, which is what the AEC reference signal needs.
final class LiveAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var queued: [Float] = []   // jitter buffer: held until `prebuffer` samples arrive
    private var playing = false
    private let prebuffer = 3600       // 150 ms

    func start(voiceProcessing: Bool, onChunk: @escaping @Sendable ([Int16]) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws {
        let input = engine.inputNode
        if voiceProcessing { try input.setVoiceProcessingEnabled(true) }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
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
            let samples = Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
            let rms = (samples.reduce(0) { $0 + Float($1) * Float($1) } / Float(samples.count)).squareRoot() / 32768
            onLevel(min(1, rms * 4))
            onChunk(samples)
        }
        engine.prepare()
        try engine.start()
        player.play()
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
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }
}
