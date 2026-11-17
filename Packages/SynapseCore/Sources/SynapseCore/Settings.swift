import Foundation

public struct WatchFolder: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var path: String
    public var modelID: String?
    public var language: String?
    public var task: TaskKind
    /// Label speakers in the subtitles written for this folder.
    public var diarize: Bool
    public var id: String { path }

    public init(path: String, modelID: String? = nil, language: String? = nil, task: TaskKind = .transcribe, diarize: Bool = false) {
        self.path = path; self.modelID = modelID; self.language = language; self.task = task; self.diarize = diarize
    }

    private enum CodingKeys: String, CodingKey { case path, modelID, language, task, diarize }

    // Settings saved before `diarize` existed must still decode, or every watched folder would be lost.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        task = try c.decodeIfPresent(TaskKind.self, forKey: .task) ?? .transcribe
        diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? false
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
    /// nil = 75% of physical memory.
    public var memoryBudgetGB: Double?
    /// Idle models are unloaded after this many minutes; 0 disables.
    public var idleUnloadMinutes: Int = 15
    /// nil = ~/Library/Application Support/Synapse/Models. Takes effect after restart.
    public var modelsFolder: String?
    /// Hugging Face access token for gated models (e.g. FLUX.2 klein 9B).
    public var hfToken: String?
    /// Path to a vOOM checkout; enables `voom:<model>` chat models served by its paging runtime.
    public var voomCheckout: String?

    public init() {}

    public var modelManagerConfig: ModelManager.Config {
        var c = ModelManager.Config.default
        if let gb = memoryBudgetGB, gb > 0 { c.budgetBytes = Int(gb * 1_073_741_824) }
        c.idleUnloadAfter = idleUnloadMinutes > 0 ? .seconds(idleUnloadMinutes * 60) : nil
        return c
    }

    /// Missing keys keep their defaults, so settings saved by older versions survive new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        defaultModelID = try c.decodeIfPresent(String.self, forKey: .defaultModelID) ?? d.defaultModelID
        bazarrModelID = try c.decodeIfPresent(String.self, forKey: .bazarrModelID)
        serverEnabled = try c.decodeIfPresent(Bool.self, forKey: .serverEnabled) ?? d.serverEnabled
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? d.allowLAN
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        libraryRoots = try c.decodeIfPresent([String].self, forKey: .libraryRoots) ?? d.libraryRoots
        watchFolders = try c.decodeIfPresent([WatchFolder].self, forKey: .watchFolders) ?? d.watchFolders
        watchingPaused = try c.decodeIfPresent(Bool.self, forKey: .watchingPaused) ?? d.watchingPaused
        cue = try c.decodeIfPresent(CueOptions.self, forKey: .cue) ?? d.cue
        memoryBudgetGB = try c.decodeIfPresent(Double.self, forKey: .memoryBudgetGB)
        idleUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
        modelsFolder = try c.decodeIfPresent(String.self, forKey: .modelsFolder)
        hfToken = try c.decodeIfPresent(String.self, forKey: .hfToken)
        voomCheckout = try c.decodeIfPresent(String.self, forKey: .voomCheckout)
    }

    public var modelsRoot: URL {
        modelsFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ModelStore.defaultRoot
    }

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
