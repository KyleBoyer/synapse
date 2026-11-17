import Foundation

public enum AudioFormat: String, Sendable, CaseIterable {
    case mp3, opus, aac, flac, wav, pcm

    public var contentType: String {
        switch self {
        case .mp3: return "audio/mpeg"
        case .opus: return "audio/ogg"
        case .aac: return "audio/aac"
        case .flac: return "audio/flac"
        case .wav: return "audio/wav"
        case .pcm: return "audio/pcm"
        }
    }

    /// nil for formats produced without ffmpeg.
    fileprivate var codecArgs: [String]? {
        switch self {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", "128k", "-f", "mp3"]
        case .aac: return ["-c:a", "aac", "-b:a", "128k", "-f", "adts"]
        case .flac: return ["-c:a", "flac", "-f", "flac"]
        case .opus: return ["-c:a", "opus", "-strict", "-2", "-ar", "48000", "-b:a", "64k", "-f", "ogg"]
        case .wav, .pcm: return nil
        }
    }
}

public struct AudioEncoder: Sendable {
    public let ffmpegURL: URL

    public init(ffmpegURL: URL) { self.ffmpegURL = ffmpegURL }

    public static func bundled() -> AudioEncoder? {
        Bundle.main.url(forAuxiliaryExecutable: "ffmpeg").map(AudioEncoder.init)
    }

    /// Encodes mono Float PCM as it arrives, so a client hears speech before synthesis finishes.
    public func encode(_ pcm: AsyncThrowingStream<[Float], Error>, sampleRate: Int, as format: AudioFormat)
        -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { out in
            guard let codec = format.codecArgs else {
                let task = Task {
                    do {
                        // Streaming WAV: unknown length, so both size fields are 0xFFFFFFFF.
                        if format == .wav { out.yield(Self.streamingWAVHeader(sampleRate: sampleRate)) }
                        for try await chunk in pcm { out.yield(PCM.pcm16LE(from: chunk)) }
                        out.finish()
                    } catch { out.finish(throwing: error) }
                }
                out.onTermination = { _ in task.cancel() }
                return
            }
            // A client that disconnects makes ffmpeg exit while we may still be writing to its stdin.
            signal(SIGPIPE, SIG_IGN)
            let p = Process()
            p.executableURL = ffmpegURL
            p.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", String(sampleRate),
                           "-ac", "1", "-i", "pipe:0"] + codec + ["pipe:1"]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
            let errText = LockedData()
            stderr.fileHandleForReading.readabilityHandler = { errText.append($0.availableData) }
            do { try p.run() } catch { out.finish(throwing: error); return }

            // stdin is written and stdout drained concurrently, or ffmpeg deadlocks on a full pipe.
            let writer = Task.detached {
                defer { try? stdin.fileHandleForWriting.close() }
                do {
                    for try await chunk in pcm {
                        // A failed write means ffmpeg is gone; the reader reports why.
                        do { try stdin.fileHandleForWriting.write(contentsOf: PCM.pcm16LE(from: chunk)) } catch { return }
                    }
                } catch { out.finish(throwing: error) }
            }
            let reader = Task.detached {
                let handle = stdout.fileHandleForReading
                while let d = try? handle.read(upToCount: 1 << 16), !d.isEmpty { out.yield(d) }
                p.waitUntilExit()
                stderr.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 || Task.isCancelled { out.finish() } else {
                    out.finish(throwing: DecodeError.ffmpeg(String(decoding: errText.data.suffix(600), as: UTF8.self)))
                }
            }
            out.onTermination = { _ in
                writer.cancel(); reader.cancel()
                if p.isRunning { p.terminate() }
            }
        }
    }

    static func streamingWAVHeader(sampleRate: Int) -> Data {
        var h = Data("RIFF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        u32(0xFFFF_FFFF); h.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        h.append(contentsOf: "data".utf8); u32(0xFFFF_FFFF)
        return h
    }
}
