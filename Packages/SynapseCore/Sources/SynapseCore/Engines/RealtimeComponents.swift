import AVFoundation
import Foundation
@preconcurrency import FluidAudio

// MARK: - Contracts (injectable; tests use fakes)

/// Voice activity detection over 16 kHz mono chunks of `RealtimeVADChunk` samples.
public protocol RealtimeVAD: Sendable {
    func speechProbability(_ chunk16k: [Float]) async throws -> Float
}
public let RealtimeVADChunk = 4096

/// Streaming speech recognition for one utterance at a time (16 kHz mono).
public protocol RealtimeASR: Sendable {
    /// Feeds audio; returns the accumulated partial transcript so far.
    func feed(_ samples16k: [Float]) async throws -> String
    /// Flushes and returns the final transcript, then resets for the next utterance.
    func finish() async throws -> String
}

/// Streaming text-to-speech. Frames are mono Float samples at `sampleRate`.
public protocol RealtimeTTS: Sendable {
    var sampleRate: Int { get }
    func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error>
}

public protocol RealtimeLLM: Sendable {
    var modelID: String { get }
    func stream(_ messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<ChatEvent, Error>
}

/// A full-duplex or utterance-translation model for `.duplex` catalog ids.
public struct RealtimeSpecialModel: Sendable {
    public var duplex: (any DuplexSpeechEngine)?
    public var translator: (any SpeechTranslationEngine)?
    /// Keeps the ModelManager lease alive for the session.
    public var keepAlive: (any Sendable)?
    public init(duplex: (any DuplexSpeechEngine)? = nil, translator: (any SpeechTranslationEngine)? = nil, keepAlive: (any Sendable)? = nil) {
        self.duplex = duplex; self.translator = translator; self.keepAlive = keepAlive
    }
}

public struct RealtimeServices: Sendable {
    public var vad: @Sendable () async throws -> any RealtimeVAD
    public var asr: @Sendable () async throws -> any RealtimeASR
    public var tts: @Sendable () async throws -> any RealtimeTTS
    /// Resolves a chat model id (nil or unknown picks the smallest downloaded chat model).
    public var llm: @Sendable (String?) async throws -> any RealtimeLLM
    /// Loads the engine for a `.duplex` catalog id.
    public var special: @Sendable (ModelSpec) async throws -> RealtimeSpecialModel

    public init(vad: @escaping @Sendable () async throws -> any RealtimeVAD,
                asr: @escaping @Sendable () async throws -> any RealtimeASR,
                tts: @escaping @Sendable () async throws -> any RealtimeTTS,
                llm: @escaping @Sendable (String?) async throws -> any RealtimeLLM,
                special: @escaping @Sendable (ModelSpec) async throws -> RealtimeSpecialModel = { spec in
                    throw EngineError.unsupported("\(spec.displayName) is not available") }) {
        self.vad = vad; self.asr = asr; self.tts = tts; self.llm = llm; self.special = special
    }
}

// MARK: - Audio helpers

enum PCM {
    static func floats(fromInt16 s: [Int16]) -> [Float] { s.map { Float($0) / 32768 } }

    static func floats(fromPCM16LE d: Data) -> [Float] {
        let n = d.count / 2
        return d.withUnsafeBytes { raw in
            (0..<n).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }

    static func pcm16LE(from f: [Float]) -> Data {
        var out = Data(capacity: f.count * 2)
        for x in f {
            let v = Int16(max(-1, min(1, x)) * 32767).littleEndian
            withUnsafeBytes(of: v) { out.append(contentsOf: $0) }
        }
        return out
    }
}

/// Streaming mono resampler on AVAudioConverter (keeps filter state across calls).
final class StreamResampler: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat, outFormat: AVAudioFormat
    private let ratio: Double

    init(from: Double, to: Double) {
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
        ratio = to / from
        converter = from == to ? nil : AVAudioConverter(from: inFormat, to: outFormat)
    }

    func convert(_ x: [Float]) -> [Float] {
        guard let converter, !x.isEmpty else { return x }
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count))!
        input.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(x.count) * ratio) + 64)!
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

// MARK: - FluidAudio wrappers

public actor FluidVAD: RealtimeVAD {
    private let manager: VadManager
    private var state: VadStreamState

    init(manager: VadManager) async {
        self.manager = manager
        state = await manager.makeStreamState()
    }

    public func speechProbability(_ chunk: [Float]) async throws -> Float {
        let r = try await manager.processStreamingChunk(chunk, state: state)
        state = r.state
        return r.probability
    }
}

public actor FluidStreamingASR: RealtimeASR {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var v = ""
        var value: String { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    }
    private let manager: StreamingEouAsrManager
    private let partial = Box()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    init(manager: StreamingEouAsrManager) async {
        self.manager = manager
        let box = partial
        await manager.setPartialCallback { box.value = $0 }
    }

    public func feed(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return partial.value }
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        _ = try await manager.process(audioBuffer: buf)
        return partial.value
    }

    public func finish() async throws -> String {
        let text = try await manager.finish()
        await manager.reset()
        partial.value = ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public actor PocketStreamingTTS: RealtimeTTS {
    public nonisolated let sampleRate = 24000
    private let manager: PocketTtsManager
    init(manager: PocketTtsManager) { self.manager = manager }

    public nonisolated func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    let frames = try await manager.synthesizeStreaming(text: text, voice: voice)
                    for try await f in frames { c.yield(f.samples) }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

public actor KokoroTTS: RealtimeTTS {
    public nonisolated let sampleRate = 24000
    private let manager: KokoroAneManager
    init(manager: KokoroAneManager) { self.manager = manager }

    public nonisolated func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    let r = try await manager.synthesizeDetailed(text: text, voice: nil, speed: Float(speed))
                    var i = 0
                    while i < r.samples.count, !Task.isCancelled {
                        c.yield(Array(r.samples[i..<min(i + 4800, r.samples.count)])); i += 4800
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// Qwen (or any chat model) behind ChatService; the service holds the ModelManager lease during generation.
public struct ChatLLM: RealtimeLLM {
    let chat: ChatService
    let spec: ModelSpec
    public var modelID: String { spec.id }
    public func stream(_ messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await chat.stream(model: spec, messages: messages, options: options)
    }
}

// Leases forward to the leased component and keep it resident for as long as the session holds them.
extension ModelLease: RealtimeVAD where T: RealtimeVAD {
    public func speechProbability(_ c: [Float]) async throws -> Float { try await value.speechProbability(c) }
}
extension ModelLease: RealtimeASR where T: RealtimeASR {
    public func feed(_ s: [Float]) async throws -> String { try await value.feed(s) }
    public func finish() async throws -> String { try await value.finish() }
}
extension ModelLease: RealtimeTTS where T: RealtimeTTS {
    public var sampleRate: Int { value.sampleRate }
    public func synthesize(_ text: String, voice: String?, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        value.synthesize(text, voice: voice, speed: speed)
    }
}

extension RealtimeServices {
    /// PocketTTS or Kokoro behind a ModelManager lease; shared by realtime sessions and `SpeechService`.
    static func ttsLease(id ttsID: String, store: ModelStore, models: ModelManager) async throws -> any RealtimeTTS {
        guard let dir = await store.folder(for: ttsID) else { throw ResolveError.notDownloaded(ttsID) }
        let bytes = (Catalog.spec(ttsID)?.approxMB ?? 100) * 1_000_000
        if ttsID == "kokoro-82m" {
            return try await models.lease("speech:kokoro-82m", as: KokoroTTS.self, estimatedBytes: bytes) {
                let m = KokoroAneManager(directory: dir)
                try await m.initialize()
                return (KokoroTTS(manager: m), unload: { await m.cleanup() })
            }
        }
        return try await models.lease("speech:pocket-tts", as: PocketStreamingTTS.self, estimatedBytes: bytes) {
            let m = PocketTtsManager(directory: dir)
            try await m.initialize()
            return (PocketStreamingTTS(manager: m), unload: { await m.cleanup() })
        }
    }

    /// Real components, all loaded through the ModelManager. VAD and ASR hold per-stream state, so each session
    /// leases its own copy (both are small); TTS is shared.
    public static func real(store: ModelStore, models: ModelManager, chat: ChatService, tts ttsID: String = "pocket-tts") -> RealtimeServices {
        @Sendable func folder(_ id: String) async throws -> URL {
            guard let f = await store.folder(for: id) else { throw ResolveError.notDownloaded(id) }
            return f
        }
        @Sendable func mb(_ id: String) -> Int { (Catalog.spec(id)?.approxMB ?? 100) * 1_000_000 }
        return RealtimeServices(
            vad: {
                let dir = try await folder("silero-vad")
                return try await models.lease("speech:silero-vad#\(UUID().uuidString)", as: FluidVAD.self, estimatedBytes: mb("silero-vad")) {
                    (await FluidVAD(manager: try await VadManager(modelDirectory: dir)), unload: {})
                }
            },
            asr: {
                let dir = try await folder("parakeet-eou-120m")
                return try await models.lease("speech:parakeet-eou-120m#\(UUID().uuidString)", as: FluidStreamingASR.self,
                                              estimatedBytes: mb("parakeet-eou-120m")) {
                    let m = StreamingEouAsrManager(chunkSize: .ms160)
                    try await m.loadModels(to: dir)
                    return (await FluidStreamingASR(manager: m), unload: { await m.cleanup() })
                }
            },
            tts: { try await ttsLease(id: ttsID, store: store, models: models) },
            llm: { requested in
                let downloaded = await store.downloaded
                let known = requested.flatMap { Catalog.spec($0) }.flatMap { $0.isChat ? $0 : nil }
                let spec = try ModelResolver.resolveChat(requested: known?.id, downloaded: downloaded)
                return ChatLLM(chat: chat, spec: spec)
            },
            special: { spec in
                let dir = try await folder(spec.id)
                if spec.id.hasPrefix("hibiki") {
                    let lease = try await models.lease("duplex:\(spec.id)", as: TranslatorBox.self, estimatedBytes: spec.estimatedBytes) {
                        let e = try await DuplexEngines.translator(spec, dir)
                        return (TranslatorBox(engine: e), unload: { await e.unload() })
                    }
                    return RealtimeSpecialModel(translator: lease.value.engine, keepAlive: lease)
                }
                let lease = try await models.lease("duplex:\(spec.id)", as: DuplexBox.self, estimatedBytes: spec.estimatedBytes) {
                    let e = try await DuplexEngines.duplex(spec, dir)
                    return (DuplexBox(engine: e), unload: { await e.unload() })
                }
                return RealtimeSpecialModel(duplex: lease.value.engine, keepAlive: lease)
            })
    }
}

struct DuplexBox: Sendable { let engine: any DuplexSpeechEngine }
struct TranslatorBox: Sendable { let engine: any SpeechTranslationEngine }
