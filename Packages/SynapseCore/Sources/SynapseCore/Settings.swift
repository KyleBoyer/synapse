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
    /// Models added from Hugging Face in Models; they join the catalog under their repo id.
    public var customModels: [CustomModel] = []
    /// Models loaded at launch and kept loaded (see ModelManager.Config.pinned).
    public var keepWarm: [String] = []
    /// Memory each chat model may use for cached prompts; nil = 1.5 GB on 16 GB Macs, 4 GB above.
    public var promptCacheGB: Double?
    /// Disk for saved prompt checkpoints, all models together; 0 turns saving off.
    public var diskCacheGB: Double = 10
    public var kvPrecision: KVPrecision = .full
    /// Main model id -> draft model id for speculative decoding.
    public var draftModels: [String: String] = [:]
    /// Days to keep work done in the app (chats, images, calls, …); nil keeps it forever, 0 saves nothing.
    public var historyDays: Int?
    /// Built-in tools Synapse runs for chat models (web search, image generation, Synapse info).
    public var tools: ToolSettings = ToolSettings()

    public init() {}

    public var promptCacheBytes: Int { promptCacheGB.map { Int($0 * 1_073_741_824) } ?? ChatService.defaultPromptCacheBytes }
    public var diskCacheBytes: Int { Int(max(0, diskCacheGB) * 1_073_741_824) }

    public var modelManagerConfig: ModelManager.Config {
        var c = ModelManager.Config.default
        if let gb = memoryBudgetGB, gb > 0 { c.budgetBytes = Int(gb * 1_073_741_824) }
        c.idleUnloadAfter = idleUnloadMinutes > 0 ? .seconds(idleUnloadMinutes * 60) : nil
        c.pinned = Set(keepWarm)
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
        customModels = try c.decodeIfPresent([CustomModel].self, forKey: .customModels) ?? []
        keepWarm = try c.decodeIfPresent([String].self, forKey: .keepWarm) ?? d.keepWarm
        promptCacheGB = try c.decodeIfPresent(Double.self, forKey: .promptCacheGB)
        diskCacheGB = try c.decodeIfPresent(Double.self, forKey: .diskCacheGB) ?? d.diskCacheGB
        kvPrecision = try c.decodeIfPresent(KVPrecision.self, forKey: .kvPrecision) ?? d.kvPrecision
        draftModels = try c.decodeIfPresent([String: String].self, forKey: .draftModels) ?? d.draftModels
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays)
        tools = try c.decodeIfPresent(ToolSettings.self, forKey: .tools) ?? d.tools
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

/// Settings for the tools Synapse runs during a chat (ServerTools).
public struct ToolSettings: Codable, Sendable, Equatable {
    public enum SearchProvider: String, Codable, Sendable, CaseIterable {
        case duckDuckGo, brave, tavily, searxng, off

        public var label: String {
            switch self {
            case .duckDuckGo: "DuckDuckGo"
            case .brave: "Brave Search"
            case .tavily: "Tavily"
            case .searxng: "SearXNG"
            case .off: "Off"
            }
        }
        public var needsKey: Bool { self == .brave || self == .tavily }
    }

    public enum Tool: String, Codable, Sendable, CaseIterable {
        case webSearch, imageGeneration, synapse, audioGeneration, videoGeneration
    }

    public var searchProvider: SearchProvider = .duckDuckGo
    /// API key for Brave Search or Tavily.
    public var searchKey: String?
    /// A SearXNG instance with the JSON format turned on, e.g. http://localhost:8080.
    public var searxngURL: String?
    public var searchResults: Int = 6
    /// The image model generate_image uses when the request names none; nil = the default image model.
    public var imageModel: String?
    /// WIDTHxHEIGHT when the request gives no size; nil = 1024x1024.
    public var imageSize: String?
    /// Tools offered to every chat request, also when the client sends none (chat apps that never ask for them).
    /// Synapse's own (time, dates, calculator, model info) and image, audio and video generation run on this Mac and
    /// send nothing out, so they start on; each generator only joins a chat when a model for it is downloaded.
    public var alwaysOn: Set<Tool> = ToolSettings.defaultOn
    public static let defaultOn: Set<Tool> = [.synapse, .imageGeneration, .audioGeneration, .videoGeneration]
    /// The tools these settings were saved with; a tool added in a later version starts as `defaultOn` says,
    /// while one already known keeps the user's choice.
    public var known: Set<Tool> = Set(Tool.allCases)
    /// Model turns per request before the tools are taken away and the model must answer.
    public var maxRounds: Int = 5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToolSettings()
        searchProvider = (try? c.decodeIfPresent(SearchProvider.self, forKey: .searchProvider)) ?? d.searchProvider
        searchKey = try c.decodeIfPresent(String.self, forKey: .searchKey)
        searxngURL = try c.decodeIfPresent(String.self, forKey: .searxngURL)
        searchResults = try c.decodeIfPresent(Int.self, forKey: .searchResults) ?? d.searchResults
        imageModel = try c.decodeIfPresent(String.self, forKey: .imageModel)
        imageSize = try c.decodeIfPresent(String.self, forKey: .imageSize)
        alwaysOn = (try? c.decodeIfPresent(Set<Tool>.self, forKey: .alwaysOn)) ?? d.alwaysOn
        // Saved before `known` existed: the tools of that version (0.1.9).
        let saved = (try? c.decodeIfPresent(Set<Tool>.self, forKey: .known)) ?? [.webSearch, .imageGeneration, .synapse]
        alwaysOn.formUnion(Self.defaultOn.subtracting(saved))
        known = Set(Tool.allCases)
        maxRounds = try c.decodeIfPresent(Int.self, forKey: .maxRounds) ?? d.maxRounds
    }
}
