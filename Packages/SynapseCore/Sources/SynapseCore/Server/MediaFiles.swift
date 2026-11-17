import AVFoundation
import Foundation
import Hummingbird

/// Video and audio that arrive inside chat requests, written to temp files the model's processor can read.
/// Only data: URLs and http(s) URLs are accepted: a client-supplied file path or file:// URL would let any
/// client read files on this Mac.
enum MediaFiles {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-media", directoryHint: .isDirectory)
    static let maxVideoBytes = 200 * 1024 * 1024
    static let maxAudioBytes = 25 * 1024 * 1024
    static let videoTypes = ["video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v"]

    /// Writes request media to a temp file. Each call also deletes files older than one hour.
    // shortcut: time-based cleanup instead of tying files to the request, because generation streams after the handler returns.
    static func write(_ data: Data, ext: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-3600)
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? fm.removeItem(at: f)
            }
        }
        let url = dir.appending(path: "\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    static func loadVideo(_ url: String) async throws -> URL {
        let (data, mime) = try await fetch(url, limit: maxVideoBytes, what: "Video")
        guard let ext = videoTypes[mime] else {
            throw HTTPError(.badRequest, message: "Unsupported video type '\(mime)'; use MP4 or MOV (H.264 or HEVC).")
        }
        let file = try write(data, ext: ext)
        let tracks = try? await AVURLAsset(url: file).loadTracks(withMediaType: .video)
        guard let tracks, !tracks.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            throw HTTPError(.badRequest, message: "The video has no video track macOS can read; use MP4 or MOV (H.264 or HEVC).")
        }
        return file
    }

    /// OpenAI `input_audio` carries base64 data plus a format name (wav, mp3, ...).
    static func loadAudio(base64: String, format: String) throws -> URL {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw HTTPError(.badRequest, message: "input_audio.data must be base64.")
        }
        guard data.count <= maxAudioBytes else { throw HTTPError(.badRequest, message: "Audio is larger than 25 MB.") }
        let ext = format.lowercased().filter(\.isLetter)
        guard ["wav", "mp3", "m4a", "flac", "ogg", "aac"].contains(ext) else {
            throw HTTPError(.badRequest, message: "Unsupported input_audio.format '\(format)'; use wav or mp3.")
        }
        return try write(data, ext: ext)
    }

    /// data:<mime>;base64,<...> or an http(s) URL; returns the bytes and their media type.
    private static func fetch(_ url: String, limit: Int, what: String) async throws -> (Data, String) {
        if url.hasPrefix("data:") {
            guard let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else {
                throw HTTPError(.badRequest, message: "\(what) data URL must be base64 encoded.")
            }
            let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count))
            guard let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
                throw HTTPError(.badRequest, message: "\(what) data URL is not valid base64.")
            }
            guard data.count <= limit else { throw HTTPError(.badRequest, message: "\(what) is larger than \(limit / 1_048_576) MB.") }
            return (data, mime.lowercased())
        }
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased()) else {
            throw HTTPError(.badRequest, message: "\(what) URL must be a data: URL or an http(s) URL.")
        }
        var req = URLRequest(url: u, timeoutInterval: 60)
        req.setValue("Synapse", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError(.badRequest, message: "Could not fetch \(what.lowercased()) \(url).")
        }
        guard data.count <= limit else { throw HTTPError(.badRequest, message: "\(what) is larger than \(limit / 1_048_576) MB.") }
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map(String.init) ?? ""
        let fromExt = ["mp4": "video/mp4", "mov": "video/quicktime", "m4v": "video/x-m4v"][u.pathExtension.lowercased()]
        return (data, videoTypes[mime.lowercased()] != nil ? mime.lowercased() : (fromExt ?? mime.lowercased()))
    }
}
