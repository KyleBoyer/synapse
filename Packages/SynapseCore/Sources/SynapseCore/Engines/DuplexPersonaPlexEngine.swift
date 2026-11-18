import AudioCommon
import Foundation
import PersonaPlex
import Synchronization

/// NVIDIA PersonaPlex 7B (Moshi-style, audio only, 24 kHz, 80 ms frames). speech-swift exposes a pull stream
/// reading a ring buffer; we run it in lock-step (one output frame per full input frame) so `push` returns
/// exactly the audio produced for the samples fed. The first push also pays the voice/system-prompt prefill.
public actor DuplexPersonaPlexEngine: DuplexSpeechEngine {
    public nonisolated var inputSampleRate: Int { 24_000 }
    public nonisolated var outputSampleRate: Int { 24_000 }
    private static let frame = 1_920

    private var model: PersonaPlexModel?
    private var ring = AudioRingBuffer(capacity: 24_000 * 30)
    private var pump: Task<Void, Never>?
    private var generation = 0
    private var fed = 0
    private var produced: [[Float]] = []
    private var delivered = 0
    private var failure: Error?
    private var ended = false
    /// Text tokens to force into the inner monologue, one per frame (spoken tool results).
    private let forced = TokenBox()
    /// The model's own monologue so far (the text of what it says).
    private let monologue = TokenBox()

    private var said = ""

    public var toolSupport: DuplexToolSupport { .spokenResults }

    init(folder: URL) async throws {
        let m = try await PersonaPlexModel.fromPretrained(
            modelId: PersonaPlexModel.defaultModelId, cacheDir: folder, offlineMode: true)
        await GPUGate.shared.acquire()
        let gate = GateRelease(); defer { gate() }
        m.warmUp()
        model = m
    }

    private func start() throws {
        guard let model else { throw EngineError.unsupported("PersonaPlex is unloaded") }
        generation += 1
        let gen = generation
        ring = AudioRingBuffer(capacity: 24_000 * 30)
        fed = 0; produced = []; delivered = 0; failure = nil; ended = false
        let forced = self.forced, monologue = self.monologue
        let stream = model.respondRealtime(userAudioBuffer: ring, waitForFullFrames: true,
                                           forcedTextToken: { forced.tokens.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
                                           onTextToken: { t in monologue.tokens.withLock { $0.append(t) } })
        pump = Task {
            do { for try await f in stream { self.append(f, gen) } } catch { self.fail(error, gen) }
            self.finish(gen)
        }
    }

    private func append(_ f: [Float], _ gen: Int) { if gen == generation { produced.append(f) } }
    private func fail(_ e: Error, _ gen: Int) { if gen == generation { failure = e } }
    private func finish(_ gen: Int) { if gen == generation { ended = true } }

    public func push(_ samples: [Float]) async throws -> [DuplexEvent] {
        // The pump only computes while we hold the gate: it waits for full input frames, which arrive only via push.
        await GPUGate.shared.acquire()
        let gate = GateRelease(); defer { gate() }
        if pump == nil || ended { try start() }
        ring.write(samples)
        fed += samples.count
        let target = fed / Self.frame
        while produced.count < target {
            if let failure { throw failure }
            if ended { throw EngineError.unsupported("PersonaPlex session ended (step limit); reset to continue") }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        if let failure { throw failure }
        let audio = produced[delivered...].flatMap { $0 }
        delivered = produced.count
        var out: [DuplexEvent] = []
        // The inner monologue is the text of what the model says (it leads its audio by a few frames).
        let text = model?.tokenizer?.decode(monologue.tokens.withLock { $0 }) ?? ""
        if text.count > said.count, text.hasPrefix(said) {
            let delta = String(text.dropFirst(said.count))
            out.append(.assistantText(delta))
            said = text
        }
        if !audio.isEmpty { out.append(.audio(audio)) }
        return out
    }

    /// Feeds `text` into the monologue a token per 80 ms frame, so the audio head speaks it at a natural pace.
    public func say(_ text: String) async {
        guard let tokens = model?.tokenizer?.encode(text), !tokens.isEmpty else { return }
        forced.tokens.withLock { $0 += tokens }
    }

    public func reset() async {
        forced.tokens.withLock { $0 = [] }; monologue.tokens.withLock { $0 = [] }; said = ""
        generation += 1
        pump?.cancel(); pump = nil
        produced = []; delivered = 0; fed = 0; ended = false; failure = nil
    }

    public func unload() async {
        await reset()
        model?.unload()
        model = nil
        DuplexAudio.freeMLXMemory()
    }
}

/// Shared with the generation task, which reads and writes it every frame.
final class TokenBox: Sendable { let tokens = Mutex<[Int32]>([]) }
