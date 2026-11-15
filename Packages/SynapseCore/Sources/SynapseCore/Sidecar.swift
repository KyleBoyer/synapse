import Foundation

public enum Sidecar {
    /// Plex/Jellyfin convention: `Movie.en.srt`, or `Movie.srt` when the language is unknown.
    public static func url(for media: URL, language: String?) -> URL {
        let base = media.deletingPathExtension()
        let name = language.map { "\(base.lastPathComponent).\($0).srt" } ?? "\(base.lastPathComponent).srt"
        return base.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func existing(for media: URL, language: String?) -> URL? {
        let fm = FileManager.default
        let exact = url(for: media, language: language)
        if language != nil || fm.fileExists(atPath: exact.path) { return fm.fileExists(atPath: exact.path) ? exact : nil }
        let dir = exact.deletingLastPathComponent()
        let prefix = media.deletingPathExtension().lastPathComponent + "."
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return names.first { $0.hasPrefix(prefix) && $0.hasSuffix(".srt") }.map { dir.appendingPathComponent($0) }
    }
}
