import Foundation

public struct WatchFolder: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var path: String
    public var modelID: String?
    public var language: String?
    public var task: TaskKind
    public var id: String { path }

    public init(path: String, modelID: String? = nil, language: String? = nil, task: TaskKind = .transcribe) {
        self.path = path; self.modelID = modelID; self.language = language; self.task = task
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public var defaultModelID: String = "parakeet-v3"
    /// nil = defaultModelID.
    public var bazarrModelID: String?
    public var serverEnabled: Bool = true
    /// whisper-asr-webservice / SubGen default, so Bazarr configs carry over.
    public var port: Int = 9000
    public var allowLAN: Bool = false
    // Kept in UserDefaults, not Keychain: ad-hoc builds change signature each release and Keychain would re-prompt.
    public var apiKey: String = Settings.generateKey()
    public var libraryRoots: [String] = []
    public var watchFolders: [WatchFolder] = []
    public var watchingPaused: Bool = false
    public var cue: CueOptions = CueOptions()

    public init() {}

    /// Roots that path-based API jobs may touch.
    public var allowedRoots: [String] { libraryRoots + watchFolders.map(\.path) }

    public static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let key = "settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            return s
        }
        let fresh = Settings()
        fresh.save(to: defaults)
        return fresh
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Thread-safe holder so actors can read the latest settings synchronously.
public final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Settings
    public init(_ value: Settings) { self.value = value }
    public var current: Settings {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
