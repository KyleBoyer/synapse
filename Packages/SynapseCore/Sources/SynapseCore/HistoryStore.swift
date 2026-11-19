import Foundation

/// Kinds of saved work, one folder each.
public enum HistoryKind: String, Codable, Sendable, CaseIterable {
    case chat, image, imageTool, video, videoTransform, speech, sound, audioEdit, call, transcript, embed
}

/// One piece of saved work. `payload` is pane-specific JSON; `files` are names inside the item's folder.
public struct HistoryItem: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let kind: HistoryKind
    public var title: String
    public var model: String
    public var createdAt: Date
    public var updatedAt: Date
    public var files: [String]
    public var payload: Data

    public init(id: UUID = UUID(), kind: HistoryKind, title: String, model: String, createdAt: Date = Date(),
                files: [String] = [], payload: Data = Data("{}".utf8)) {
        self.id = id; self.kind = kind; self.title = title; self.model = model
        self.createdAt = createdAt; self.updatedAt = createdAt; self.files = files; self.payload = payload
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: payload) }
}

/// Work done in the app's panes, kept across launches until deleted. API requests never come here: only the app
/// target saves (HistoryRulesTests checks that no route or service references this type).
///
/// Layout: `<root>/<kind>/<uuid>/{meta.json, files…}`. meta.json is written last, so a folder without it is a
/// half-finished save, which `prune` removes.
public actor HistoryStore {
    public let root: URL
    private var cache: [HistoryKind: [HistoryItem]] = [:]

    public init(root: URL) { self.root = root }

    /// The app's location: ~/Library/Application Support/Synapse/History.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Synapse/History", directoryHint: .isDirectory)
    }

    private func folder(_ kind: HistoryKind) -> URL { root.appending(path: kind.rawValue, directoryHint: .isDirectory) }
    private func folder(_ item: HistoryItem) -> URL { folder(item.kind).appending(path: item.id.uuidString, directoryHint: .isDirectory) }

    /// Newest first.
    public func list(_ kind: HistoryKind) -> [HistoryItem] {
        if let c = cache[kind] { return c }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder(kind), includingPropertiesForKeys: nil)) ?? []
        let items = dirs.compactMap { d -> HistoryItem? in
            guard let data = try? Data(contentsOf: d.appending(path: "meta.json")) else { return nil }
            return try? Self.decoder.decode(HistoryItem.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
        cache[kind] = items
        return items
    }

    /// Creates or replaces an item (a chat saves the same id after every reply). Files are written first and the
    /// item's file list is what `files` holds, so files from an earlier save that are not listed are removed.
    public func save(_ item: HistoryItem, files: [String: Data] = [:]) throws {
        var item = item
        item.updatedAt = Date()
        let dir = folder(item)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: dir.appending(path: Self.safe(name)), options: .atomic) }
        item.files = Array(Set(item.files).union(files.keys.map(Self.safe))).sorted()
        let present = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in present where f != "meta.json" && !item.files.contains(f) { try? FileManager.default.removeItem(at: dir.appending(path: f)) }
        try Self.encoder.encode(item).write(to: dir.appending(path: "meta.json"), options: .atomic)
        var list = cache[item.kind] ?? self.list(item.kind)
        list.removeAll { $0.id == item.id }
        list.insert(item, at: 0)
        cache[item.kind] = list
    }

    /// Copies a large file (a video) into the item's folder; call before `save` and list its name in `files`.
    /// A file already there under that name is kept (a chat re-saves its attachments after every reply).
    public func addFile(_ item: HistoryItem, name: String, copying url: URL) throws {
        let dir = folder(item)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: Self.safe(name))
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try FileManager.default.copyItem(at: url, to: dest)
    }

    public func url(_ item: HistoryItem, _ name: String) -> URL { folder(item).appending(path: Self.safe(name)) }

    public func data(_ item: HistoryItem, _ name: String) -> Data? { try? Data(contentsOf: url(item, name)) }

    public func delete(_ ids: [UUID], kind: HistoryKind) {
        for id in ids { try? FileManager.default.removeItem(at: folder(kind).appending(path: id.uuidString)) }
        cache[kind]?.removeAll { ids.contains($0.id) }
    }

    /// One kind, or everything when `kind` is nil.
    public func deleteAll(_ kind: HistoryKind? = nil) {
        if let kind {
            try? FileManager.default.removeItem(at: folder(kind))
            cache[kind] = []
        } else {
            try? FileManager.default.removeItem(at: root)
            cache = [:]
        }
    }

    /// Removes items last updated before `date`, and half-written folders.
    public func prune(olderThan date: Date?) {
        for kind in HistoryKind.allCases {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: folder(kind), includingPropertiesForKeys: nil)) ?? []
            for d in dirs {
                let meta = (try? Data(contentsOf: d.appending(path: "meta.json"))).flatMap { try? Self.decoder.decode(HistoryItem.self, from: $0) }
                if meta == nil || (date.map { meta!.updatedAt < $0 } ?? false) { try? FileManager.default.removeItem(at: d) }
            }
            cache[kind] = nil
        }
    }

    public func totalBytes() -> Int {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return e.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }

    /// File names come from the app, but a name must never climb out of the item's folder.
    private static func safe(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." || last == "meta.json" ? "file" : last
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
