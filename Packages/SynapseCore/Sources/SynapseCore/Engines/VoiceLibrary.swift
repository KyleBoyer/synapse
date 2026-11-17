import Foundation
@preconcurrency import FluidAudio

/// A voice cloned from a short clip. `id` is what clients send as `voice` (OpenAI's custom voices use `voice_…`).
public struct CustomVoice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public let createdAt: Int
    /// The consent recording that authorized it (required on the API; the app records the user's confirmation instead).
    public let consentID: String?
    /// Seconds of the sample the voice was taken from (PocketTTS reads at most 10).
    public let seconds: Double
}

/// A recording of the speaker agreeing to have their voice cloned (OpenAI's voice consents).
public struct VoiceConsent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var language: String
    public let createdAt: Int
}

/// Custom voices and consent recordings on disk under `<models>/voices/`: `<voice id>/voice.json` with the PocketTTS
/// conditioning in `voice.bin`, and `consents/<consent id>/consent.json` beside the recording.
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

    func add(name: String, consentID: String?, seconds: Double, data: PocketTtsVoiceData) throws -> CustomVoice {
        let v = CustomVoice(id: Self.newID("voice_"), name: name, createdAt: Int(Date().timeIntervalSince1970),
                            consentID: consentID, seconds: seconds)
        let dir = root.appending(path: v.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PocketTtsVoiceCloner.saveVoice(data, to: dir.appending(path: "voice.bin"))
        try JSONEncoder().encode(v).write(to: dir.appending(path: "voice.json"))
        return v
    }

    func voiceData(_ id: String) throws -> PocketTtsVoiceData? {
        guard voice(id) != nil else { return nil }
        return try PocketTtsVoiceCloner.loadVoice(from: root.appending(path: id).appending(path: "voice.bin"))
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

    /// Keeps the recording beside its metadata. Synapse stores consent; it does not check what the recording says.
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

/// A TTS engine that can take a voice from a clip (PocketTTS, through its Mimi encoder).
protocol VoiceCloning: Sendable {
    /// `wav`: 24 kHz mono; PocketTTS reads the first 10 seconds and needs at least 1.
    func clone(wav: URL) async throws -> PocketTtsVoiceData
    func synthesize(_ text: String, voiceData: PocketTtsVoiceData) -> AsyncThrowingStream<[Float], Error>
}

extension ModelLease: VoiceCloning where T: VoiceCloning {
    func clone(wav: URL) async throws -> PocketTtsVoiceData { try await value.clone(wav: wav) }
    func synthesize(_ text: String, voiceData: PocketTtsVoiceData) -> AsyncThrowingStream<[Float], Error> {
        value.synthesize(text, voiceData: voiceData)
    }
}
