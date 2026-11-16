import AudioCommon
import Foundation
import PersonaPlex

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

    init(folder: URL) async throws {
        let m = try await PersonaPlexModel.fromPretrained(
            modelId: PersonaPlexModel.defaultModelId, cacheDir: folder, offlineMode: true)
        m.warmUp()
        model = m
    }

    private func start() throws {
        guard let model else { throw EngineError.unsupported("PersonaPlex is unloaded") }
        generation += 1
        let gen = generation
        ring = AudioRingBuffer(capacity: 24_000 * 30)
        fed = 0; produced = []; delivered = 0; failure = nil; ended = false
        let stream = model.respondRealtime(userAudioBuffer: ring, waitForFullFrames: true)
        pump = Task {
            do { for try await f in stream { self.append(f, gen) } } catch { self.fail(error, gen) }
            self.finish(gen)
        }
    }

    private func append(_ f: [Float], _ gen: Int) { if gen == generation { produced.append(f) } }
    private func fail(_ e: Error, _ gen: Int) { if gen == generation { failure = e } }
    private func finish(_ gen: Int) { if gen == generation { ended = true } }

    public func push(_ samples: [Float]) async throws -> [DuplexEvent] {
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
        return audio.isEmpty ? [] : [.audio(audio)]
    }

    public func reset() async {
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
