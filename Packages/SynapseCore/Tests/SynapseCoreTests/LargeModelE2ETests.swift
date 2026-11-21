import AVFoundation
import Foundation
import XCTest
@testable import SynapseCore

/// Confirms the Mac Studio-sized models run through Synapse's own code on a smaller Mac, from quantized copies.
/// Each test is opt-in: SYNAPSE_E2E=1 plus the folder it needs (see each test). The models root
/// (SYNAPSE_MODELS_DIR) supplies parakeet-v3 for checking speech, and the Python runtimes.
final class LargeModelE2ETests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var realRoot: URL { env["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot }

    /// A throwaway store whose manifest maps `id` to `folder`, sharing the real Python runtimes.
    private func store(_ id: String, _ folder: String) throws -> ModelStore {
        let root = try TestSupport.tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "confirm"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appending(path: "confirm/\(id)"), withDestinationURL: URL(fileURLWithPath: folder))
        try fm.createSymbolicLink(at: root.appending(path: "runtimes"), withDestinationURL: realRoot.appending(path: "runtimes"))
        try JSONEncoder().encode([id: "confirm/\(id)"]).write(to: root.appending(path: "manifest.json"))
        return ModelStore(root: root)
    }

    private func fixtureWAV() async throws -> URL {
        let dir = try TestSupport.tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try await AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()).decodeToWAV(.media(TestSupport.fixture("en.m4a")), into: dir)
    }

    private func ask(_ chat: ChatService, _ spec: ModelSpec, _ text: String, images: [Data] = [], videos: [URL] = [],
                     audios: [URL] = []) async throws -> String {
        var out = ""
        let start = Date()
        for try await e in try await chat.stream(model: spec, messages: [ChatMessage(role: .user, text: text, images: images, videos: videos, audios: audios)],
                                                 options: ChatOptions(maxTokens: 60, temperature: 0)) {
            if case .delta(let d) = e { out += d }
        }
        print(String(format: "[%@] %.1f s: %@", spec.id, Date().timeIntervalSince(start), out))
        return out
    }

    /// What Parakeet hears in `samples` (24 kHz).
    private func transcribe(_ samples: [Float], rate: Int) async throws -> String {
        let dir = try TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "speech.wav")
        try PCM.wav16(samples, rate: rate).write(to: wav)
        var s = Settings(); s.defaultModelID = "parakeet-v3"
        let q = JobQueue(store: ModelStore(root: realRoot), decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: SettingsBox(s))
        return await q.run(JobRequest(input: .media(wav), origin: .api)).transcript?.text ?? ""
    }

    /// Inkling 2 Mini from the catalog: the store fetches this Mac's files into SYNAPSE_MODELS_DIR and prepares them
    /// (requantized under 32 GB), then llama.cpp answers a text question and an image question.
    func testInkling2MiniAnswersTextAndImages() async throws {
        guard env["SYNAPSE_E2E"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1") }
        let store = ModelStore(root: realRoot)
        if await !store.downloaded.contains("inkling-2-mini") { _ = try await store.download("inkling-2-mini", token: nil) { _ in } }
        let models = ModelManager()
        let chat = ChatService(store: store, models: models)
        let spec = try XCTUnwrap(Catalog.spec("inkling-2-mini"))
        let found = await store.folder(for: spec.id)
        let folder = try XCTUnwrap(found)
        XCTAssertTrue(ModelPrep.isPrepared(folder) || ModelPrep.step(for: spec) == nil)
        let capital = try await ask(chat, spec, "What is the capital of France? Answer with one word.")
        XCTAssertTrue(capital.contains("Paris"), capital)
        let zebra = try Data(contentsOf: TestSupport.fixture("zebra.jpg"))
        let animal = try await ask(chat, spec, "What animal is in this picture? Answer with one word.", images: [zebra])
        XCTAssertTrue(animal.lowercased().contains("zebra"), animal)
        await models.unloadAllIdle()
    }

    /// SYNAPSE_CONFIRM_MINICPM = a MiniCPM-o 4.5 folder (mlx-vlm conversion of openbmb/MiniCPM-o-4_5).
    func testMiniCPMOHearsSeesAndSpeaks() async throws {
        guard env["SYNAPSE_E2E"] == "1", let folder = env["SYNAPSE_CONFIRM_MINICPM"] else { throw XCTSkip("set SYNAPSE_E2E=1 and SYNAPSE_CONFIRM_MINICPM") }
        let spec = try XCTUnwrap(Catalog.spec("minicpm-o-4.5"))
        let models = ModelManager()
        let chat = ChatService(store: try store(spec.id, folder), models: models)
        let wav = try await fixtureWAV()
        let heard = try await ask(chat, spec, "Transcribe the audio.", audios: [wav])
        XCTAssertTrue(heard.lowercased().contains("fox"), heard)
        let seen = try await ask(chat, spec, "What animal is this? Answer with one word.", images: [try Data(contentsOf: TestSupport.fixture("zebra.jpg"))])
        XCTAssertTrue(seen.lowercased().contains("zebra"), seen)
        try await Task.sleep(for: .milliseconds(200))
        await models.unloadAllIdle()   // the text server and the voice sidecar each hold a copy

        var text = "", audio: [Float] = [], rate = 24000
        let start = Date()
        let voice = try await chat.voice(spec)
        for try await e in voice.respond([ChatMessage(role: .user, text: "Repeat exactly what the speaker says.", audios: [wav])],
                                         options: ChatOptions(maxTokens: 200)) {
            switch e {
            case .text(let t): text += t
            case .audio(let a, let r): audio += a; rate = r
            case .done, .toolCall: break
            }
        }
        let spoken = try await transcribe(audio, rate: rate)
        print(String(format: "[minicpm voice] %.1f s; %.1f s of speech: %@ | Parakeet hears: %@", Date().timeIntervalSince(start),
                     Double(audio.count) / Double(rate), text, spoken))
        XCTAssertTrue(spoken.lowercased().contains("fox"), spoken)
    }

    /// The catalog flow on a smaller Mac: download MiniCPM-o's official weights, prep converts them to 4-bit, chat works.
    /// SYNAPSE_CONFIRM_PREP=1; downloads ~20 GB into a throwaway store (the Python runtimes are shared).
    func testMiniCPMODownloadIsPreparedForThisMac() async throws {
        guard env["SYNAPSE_E2E"] == "1", env["SYNAPSE_CONFIRM_PREP"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1 and SYNAPSE_CONFIRM_PREP=1") }
        let spec = try XCTUnwrap(Catalog.spec("minicpm-o-4.5"))
        XCTAssertEqual(ModelPrep.step(for: spec), .quantize4, "this check is for Macs under 32 GB")
        let root = try TestSupport.tempDir(in: URL(fileURLWithPath: env["SYNAPSE_CONFIRM_SCRATCH"] ?? NSTemporaryDirectory()))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "runtimes"), withDestinationURL: realRoot.appending(path: "runtimes"))
        try JSONEncoder().encode([String: String]()).write(to: root.appending(path: "manifest.json"))
        let store = ModelStore(root: root)
        let start = Date()
        let folder = try await store.download(spec.id, token: HFDownloader.cliToken()) { _ in }
        let mb = (try FileManager.default.subpathsOfDirectory(atPath: folder.path)).reduce(0) { sum, p in
            sum + ((try? FileManager.default.attributesOfItem(atPath: folder.appending(path: p).path)[.size] as? Int) ?? 0)
        } / 1_000_000
        print(String(format: "[prep] downloaded and prepared in %.0f s; folder now %d MB", Date().timeIntervalSince(start), mb))
        XCTAssertTrue(ModelPrep.isPrepared(folder))
        XCTAssertLessThan(mb, 9000, "the bf16 weights were replaced by the 4-bit copy")
        let models = ModelManager()
        let chat = ChatService(store: store, models: models)
        let seen = try await ask(chat, spec, "What animal is this? Answer with one word.", images: [try Data(contentsOf: TestSupport.fixture("zebra.jpg"))])
        XCTAssertTrue(seen.lowercased().contains("zebra"), seen)
        try await Task.sleep(for: .milliseconds(200))
        await models.unloadAllIdle()
    }

    /// SYNAPSE_CONFIRM_QWEN3OMNI = a Qwen3-Omni 30B-A3B folder (any mlx-vlm quantization).
    func testQwen3OmniHearsAndSees() async throws {
        guard env["SYNAPSE_E2E"] == "1", let folder = env["SYNAPSE_CONFIRM_QWEN3OMNI"] else { throw XCTSkip("set SYNAPSE_E2E=1 and SYNAPSE_CONFIRM_QWEN3OMNI") }
        let spec = try XCTUnwrap(Catalog.spec("qwen3-omni-30b"))
        let models = ModelManager()
        let chat = ChatService(store: try store(spec.id, folder), models: models)
        // Not asserted: with mlx-vlm 0.8.0 the same sounds are transcribed or derail into "<|im_start|>" depending
        // on a few hundred samples of length (also through mlx-vlm's own server). Printed for the record.
        let heard = try await ask(chat, spec, "Transcribe the audio.", audios: [try await fixtureWAV()])
        print("[qwen3-omni audio] \(heard.isEmpty ? "(empty)" : heard)")
        let seen = try await ask(chat, spec, "What animal is this? Answer with one word.", images: [try Data(contentsOf: TestSupport.fixture("zebra.jpg"))])
        XCTAssertTrue(seen.lowercased().contains("zebra"), seen)
        // mlx-vlm 0.8.0's Qwen3-Omni video path returns only control tokens, so video is refused up front.
        let canWatch = await chat.supportsVideo(spec)
        XCTAssertFalse(canWatch)
        try await Task.sleep(for: .milliseconds(200))
        await models.unloadAllIdle()
    }

    /// The real LTX-2.3 download in SYNAPSE_MODELS_DIR, a short clip. On Macs under 64 GB this is low-memory mode.
    func testLTXGeneratesAClip() async throws {
        guard env["SYNAPSE_E2E"] == "1", env["SYNAPSE_CONFIRM_LTX"] == "1" else { throw XCTSkip("set SYNAPSE_E2E=1 and SYNAPSE_CONFIRM_LTX=1") }
        let store = ModelStore(root: realRoot)
        let maybeFolder = await store.folder(for: "ltx-2.3-distilled")
        let folder = try XCTUnwrap(maybeFolder, "ltx-2.3-distilled is not downloaded")
        let out = FileManager.default.temporaryDirectory.appending(path: "ltx-confirm-\(UUID().uuidString).mp4")
        let start = Date()
        let progress = ProgressLog()
        try await MLXVideoEngine(folder: folder).generate(
            VideoRequest(prompt: "A red fox walking through snow, cinematic", width: 384, height: 256, frames: 25, seed: 7),
            to: out) { progress.add($0) }
        let asset = AVURLAsset(url: out)
        let seconds = try await asset.load(.duration).seconds
        let thumb = await VideoFile.thumbnail(of: out)
        print(String(format: "[ltx] %.0f s total; clip %.2f s; progress steps %d; thumbnail %d bytes; %@", Date().timeIntervalSince(start),
                     seconds, progress.count, thumb?.count ?? 0, out.path))
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertGreaterThan(thumb?.count ?? 0, 2000, "a real frame, not a blank one")
        XCTAssertGreaterThan(progress.count, 2, "progress was parsed from mlx-video's output")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var count: Int { lock.withLock { values.count } }
}
