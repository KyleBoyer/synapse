import AVFoundation
import XCTest
@testable import SynapseCore

/// Real full-duplex / translation models. SYNAPSE_DUPLEX_E2E_IDS=hibiki-zero-3b,personaplex-7b,voicechat-11b[-int5], models in
/// SYNAPSE_MODELS_DIR (download with DownloadTool). Run: scripts/with-gpu-lock.sh scripts/test-chat-e2e.sh DuplexE2ETests
final class DuplexE2ETests: XCTestCase {
    private var ids: Set<String> = []
    private var root: URL!
    private let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SYNAPSE_DUPLEX_OUT"] ?? NSTemporaryDirectory())

    override func setUp() async throws {
        guard let v = ProcessInfo.processInfo.environment["SYNAPSE_DUPLEX_E2E_IDS"] else { throw XCTSkip("set SYNAPSE_DUPLEX_E2E_IDS") }
        ids = Set(v.split(separator: ",").map(String.init))
        root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
    }

    private func spec(_ id: String) throws -> (ModelSpec, URL) {
        guard ids.contains(id) else { throw XCTSkip("\(id) not in SYNAPSE_DUPLEX_E2E_IDS") }
        let s = Catalog.spec(id)!
        return (s, DuplexModels.folder(s, root: root))
    }

    /// macOS `say` -> mono Float samples at `rate`.
    private func say(_ text: String, voice: String, rate: Int) throws -> [Float] {
        let file = out.appending(path: "say-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", file.path, "--data-format=LEF32@\(rate)", text]
        try p.run(); p.waitUntilExit()
        let f = try AVAudioFile(forReading: file)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    private func writeWAV(_ x: [Float], rate: Int, name: String) throws -> URL {
        let url = out.appending(path: name)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
        buf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16], commonFormat: .pcmFormatFloat32, interleaved: false)
        try f.write(from: buf)
        print("[wav] \(url.path) \(String(format: "%.2f", Double(x.count) / Double(rate)))s rms=\(rms(x))")
        return url
    }

    private func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }

    /// Best effort: transcribe with whisper-tiny through JobQueue.
    private func transcribe(_ wav: URL) async -> String {
        do {
            let store = ModelStore(root: FileManager.default.temporaryDirectory.appending(path: "synapse-e2e-models"))
            _ = try await store.download("whisper-tiny") { _ in }
            var s = Settings(); s.defaultModelID = "whisper-tiny"
            let q = JobQueue(store: store, decoder: AudioDecoder(ffmpegURL: try TestSupport.ffmpeg()), settings: SettingsBox(s))
            let snap = await q.run(JobRequest(input: .media(wav), modelID: "whisper-tiny", language: "en", origin: .gui))
            return snap.transcript?.text ?? "(no transcript)"
        } catch { return "(transcription unavailable: \(error))" }
    }

    func testHibikiTranslatesFrenchToEnglish() async throws {
        let (s, dir) = try spec("hibiki-zero-3b")
        let src = try say("Bonjour, je voudrais réserver une table pour deux personnes ce soir. Quel temps fait-il demain à Paris ?", voice: "Thomas", rate: 24000)
        _ = try writeWAV(src, rate: 24000, name: "hibiki-in-fr.wav")
        var t = Date()
        let engine = try await DuplexEngines.translator(s, dir)
        print("[hibiki] load \(Date().timeIntervalSince(t))s")
        t = Date()
        let r = try await engine.translate(src, sampleRate: 24000, sourceLanguage: "fr")
        let secs = Date().timeIntervalSince(t), dur = Double(r.audio.count) / Double(r.sampleRate)
        print("[hibiki] \(secs)s for \(dur)s output (src \(Double(src.count) / 24000)s) text=\(r.text)")
        let wav = try writeWAV(r.audio, rate: r.sampleRate, name: "hibiki-out-en.wav")
        print("[hibiki] whisper: \(await transcribe(wav))")
        XCTAssertGreaterThan(rms(r.audio), 0.005)
        let words = Set(r.text.lowercased().split { !$0.isLetter }.map(String.init))
        XCTAssertFalse(words.isDisjoint(with: ["the", "a", "i", "table", "weather", "tomorrow", "would", "like", "for", "to", "is", "in", "two", "tonight"]), r.text)
        await engine.unload()
    }

    /// Question clip + 8 s silence (time for the spoken reply), in 80 ms-ish chunks; returns assistant audio and text.
    private func converse(_ engine: any DuplexSpeechEngine, label: String,
                          question: String = "Hello! My name is Sam. Can you tell me what the capital of France is?",
                          silence: Int = 8,
                          onCall: (String, String) async throws -> Void = { _, _ in }) async throws -> (audio: [Float], user: String, text: String) {
        let rate = await engine.inputSampleRate
        var clip = try say(question, voice: "Samantha", rate: rate)
        clip += [Float](repeating: 0, count: rate * silence)
        _ = try writeWAV(clip, rate: rate, name: "\(label)-in-en.wav")
        let chunk = rate * 80 / 1000
        var audio: [Float] = [], user = "", text = ""
        let t = Date()
        var i = 0
        while i < clip.count {
            for e in try await engine.push(Array(clip[i..<min(i + chunk, clip.count)])) {
                switch e {
                case .audio(let a): audio += a
                case .userText(let u): user += u
                case .assistantText(let a): text += a
                case .toolCall(let name, let arguments):
                    print("[\(label)] tool call \(name) \(arguments) at \(Double(i) / Double(rate))s")
                    try await onCall(name, arguments)
                }
            }
            i += chunk
        }
        let secs = Date().timeIntervalSince(t)
        print("[\(label)] pushed \(Double(clip.count) / Double(rate))s in \(secs)s (RTF \(secs / (Double(clip.count) / Double(rate)))) user=\(user) text=\(text)")
        return (audio, user, text)
    }

    func testPersonaPlexAnswers() async throws {
        let (s, dir) = try spec("personaplex-7b")
        let t = Date()
        let engine = try await DuplexEngines.duplex(s, dir)
        print("[personaplex] load \(Date().timeIntervalSince(t))s")
        let r = try await converse(engine, label: "personaplex")
        let wav = try writeWAV(r.audio, rate: await engine.outputSampleRate, name: "personaplex-out.wav")
        print("[personaplex] whisper: \(await transcribe(wav))")
        XCTAssertGreaterThan(rms(r.audio), 0.005)
        await engine.unload()
    }

    func testVoiceChatAnswers() async throws {
        let (s, dir) = try spec(ids.contains("voicechat-11b-int5") ? "voicechat-11b-int5" : "voicechat-11b")
        let t = Date()
        let engine = try await DuplexEngines.duplex(s, dir)
        print("[voicechat] load \(Date().timeIntervalSince(t))s")
        let r = try await converse(engine, label: "voicechat")
        let wav = try writeWAV(r.audio, rate: await engine.outputSampleRate, name: "voicechat-out.wav")
        print("[voicechat] whisper: \(await transcribe(wav))")
        XCTAssertGreaterThan(rms(r.audio), 0.005)
        XCTAssertFalse(r.user.trimmingCharacters(in: .whitespaces).isEmpty, "no user transcript")
        XCTAssertTrue(r.text.lowercased().contains("paris"), r.text)
        XCTAssertFalse(r.text.contains("<SPECIAL"), r.text)
        await engine.unload()
    }

    private static let weather = ChatTool(name: "get_weather", description: "Get the current weather for a city",
                                          parametersJSON: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#)

    /// VoiceChat calls the tool on its function channel, hears the result, and speaks it.
    func testVoiceChatCallsToolAndSpeaksResult() async throws {
        let (s, dir) = try spec(ids.contains("voicechat-11b-int5") ? "voicechat-11b-int5" : "voicechat-11b")
        let engine = try await DuplexEngines.duplex(s, dir)
        await engine.setTools([Self.weather])
        var calls: [(String, String)] = []
        let r = try await converse(engine, label: "voicechat-tools", question: "What's the weather like in Paris right now?", silence: 14) { name, args in
            calls.append((name, args))
            try await engine.toolResult(name: name, output: #"{"city":"Paris","temperature_c":18,"sky":"light rain"}"#)
        }
        let wav = try writeWAV(r.audio, rate: await engine.outputSampleRate, name: "voicechat-tools-out.wav")
        let heard = await transcribe(wav)
        print("[voicechat-tools] whisper: \(heard)")
        XCTAssertEqual(calls.first?.0, "get_weather")
        XCTAssertTrue(calls.first?.1.lowercased().contains("paris") == true, calls.first?.1 ?? "no call")
        let said = (r.text + " " + heard).lowercased()
        XCTAssertTrue(said.contains("rain") || said.contains("18") || said.contains("eighteen"), said)
        await engine.unload()
    }

    /// PersonaPlex says a tool's answer in its own voice when it is forced into the inner monologue.
    func testPersonaPlexSpeaksForcedAnswer() async throws {
        let (s, dir) = try spec("personaplex-7b")
        let engine = try await DuplexEngines.duplex(s, dir)
        let rate = await engine.inputSampleRate, chunk = rate * 80 / 1000
        let clip = try say("What's the weather like in Paris right now?", voice: "Samantha", rate: rate)
        var audio: [Float] = [], text = ""
        func run(_ x: [Float]) async throws {
            var i = 0
            while i < x.count {
                for e in try await engine.push(Array(x[i..<min(i + chunk, x.count)])) {
                    if case .audio(let a) = e { audio += a }
                    if case .assistantText(let t) = e { text += t }
                }
                i += chunk
            }
        }
        try await run(clip + [Float](repeating: 0, count: rate))
        await engine.say("It is eighteen degrees with light rain in Paris.")
        try await run([Float](repeating: 0, count: rate * 8))
        let wav = try writeWAV(audio, rate: await engine.outputSampleRate, name: "personaplex-said-out.wav")
        let heard = await transcribe(wav)
        print("[personaplex-said] text=\(text) whisper: \(heard)")
        XCTAssertTrue(text.lowercased().contains("light rain"), text)
        XCTAssertTrue(["rain", "18", "eighteen"].contains { heard.lowercased().contains($0) }, heard)
        await engine.unload()
    }
}
