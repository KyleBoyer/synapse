import Foundation

/// A voice cloned from a short clip. `id` is what clients send as `voice` (OpenAI's custom voices use `voice_…`).
/// The clip itself is kept, so every model that clones (PocketTTS, Qwen3-TTS, VoxCPM2, Chatterbox) can speak it.
public struct CustomVoice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public let createdAt: Int
    /// Seconds of reference audio kept (the first 10 of the sample).
    public let seconds: Double
    /// What the clip says; transcribed when the voice is made. Qwen3-TTS needs it.
    public let transcript: String?
}

/// What a cloning engine reads: the 24 kHz mono clip, its transcript, and the voice's folder for derived data
/// (PocketTTS caches its conditioning there).
struct VoiceReference: Sendable {
    let sample: URL
    let transcript: String?
    let folder: URL
}

/// A recording of the speaker agreeing to have their voice cloned (OpenAI's voice consents).
public struct VoiceConsent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var language: String
    public let createdAt: Int
}

/// Custom voices and consent recordings on disk under `<models>/voices/`: `<voice id>/voice.json` beside the clip
/// (`sample.wav`), and `consents/<consent id>/consent.json` beside the recording. Consent is kept for API clients
/// that send it; nothing requires it.
public actor VoiceLibrary {
    let root: URL
    private var consentsRoot: URL { root.appending(path: "consents", directoryHint: .isDirectory) }

    public init(root: URL) { self.root = root }

    static func newID(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    }

    // MARK: Voices

    public func voices() -> [CustomVoice] {
        Self.read(CustomVoice.self, in: root, file: "voice.json").sorted { $0.createdAt < $1.createdAt }
    }

    public func voice(_ id: String) -> CustomVoice? { voices().first { $0.id == id } }

    /// `sample`: 24 kHz mono WAV, already cut to what is kept.
    func add(name: String, sample: URL, seconds: Double, transcript: String?) throws -> CustomVoice {
        let v = CustomVoice(id: Self.newID("voice_"), name: name, createdAt: Int(Date().timeIntervalSince1970),
                            seconds: seconds, transcript: transcript)
        let dir = root.appending(path: v.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sample, to: dir.appending(path: "sample.wav"))
        try JSONEncoder().encode(v).write(to: dir.appending(path: "voice.json"))
        return v
    }

    func reference(_ id: String) -> VoiceReference? {
        guard let v = voice(id) else { return nil }
        let dir = root.appending(path: id, directoryHint: .isDirectory)
        return VoiceReference(sample: dir.appending(path: "sample.wav"), transcript: v.transcript, folder: dir)
    }

    public func deleteVoice(_ id: String) -> Bool {
        guard voice(id) != nil else { return false }
        return (try? FileManager.default.removeItem(at: root.appending(path: id))) != nil
    }

    // MARK: Consents

    public func consents() -> [VoiceConsent] {
        Self.read(VoiceConsent.self, in: consentsRoot, file: "consent.json").sorted { $0.createdAt < $1.createdAt }
    }

    public func consent(_ id: String) -> VoiceConsent? { consents().first { $0.id == id } }

    /// Keeps the recording beside its metadata, for OpenAI clients that create consents; voices do not need one.
    public func addConsent(name: String, language: String, recording: URL) throws -> VoiceConsent {
        let c = VoiceConsent(id: Self.newID("cons_"), name: name, language: language, createdAt: Int(Date().timeIntervalSince1970))
        let dir = consentsRoot.appending(path: c.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = recording.pathExtension.isEmpty ? "bin" : recording.pathExtension
        try FileManager.default.copyItem(at: recording, to: dir.appending(path: "recording.\(ext)"))
        try JSONEncoder().encode(c).write(to: dir.appending(path: "consent.json"))
        return c
    }

    public func renameConsent(_ id: String, to name: String) throws -> VoiceConsent? {
        guard var c = consent(id) else { return nil }
        c.name = name
        try JSONEncoder().encode(c).write(to: consentsRoot.appending(path: id).appending(path: "consent.json"))
        return c
    }

    public func deleteConsent(_ id: String) -> Bool {
        guard consent(id) != nil else { return false }
        return (try? FileManager.default.removeItem(at: consentsRoot.appending(path: id))) != nil
    }

    private static func read<T: Decodable>(_ type: T.Type, in dir: URL, file: String) -> [T] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? JSONDecoder().decode(T.self, from: Data(contentsOf: $0.appending(path: file))) }
    }
}

/// A TTS engine that speaks in the voice of a reference clip.
protocol ReferenceVoiceTTS: RealtimeTTS {
    func synthesize(_ text: String, reference: VoiceReference, speed: Double) -> AsyncThrowingStream<[Float], Error>
}

extension ModelLease: ReferenceVoiceTTS where T: ReferenceVoiceTTS {
    func synthesize(_ text: String, reference: VoiceReference, speed: Double) -> AsyncThrowingStream<[Float], Error> {
        value.synthesize(text, reference: reference, speed: speed)
    }
}
