import AVFoundation
import XCTest
@testable import SynapseCore

final class AudioDecoderTests: XCTestCase {
    private func decoder() throws -> AudioDecoder {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["SYNAPSE_FFMPEG"]
            ?? repo.appendingPathComponent("vendor/ffmpeg/bin/ffmpeg").path
        guard FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("no ffmpeg at \(path)") }
        return AudioDecoder(ffmpegURL: URL(fileURLWithPath: path))
    }

    private func fixture(_ name: String) throws -> URL {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return dir.appendingPathComponent(name)
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func check(_ input: AudioInput, expected: Double) async throws {
        let wav = try await decoder().decodeToWAV(input, into: tempDir())
        let f = try AVAudioFile(forReading: wav)
        XCTAssertEqual(f.fileFormat.sampleRate, 16000)
        XCTAssertEqual(f.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(f.length) / f.fileFormat.sampleRate, expected, accuracy: 0.2)
    }

    private func sourceDuration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    func testDecodeM4A() async throws {
        let url = try fixture("en.m4a")
        try await check(.media(url), expected: sourceDuration(url))
    }

    func testDecodeMKV() async throws {
        // mkv is a remux of en.m4a, so the m4a duration is the reference.
        try await check(.media(fixture("en.mkv")), expected: sourceDuration(fixture("en.m4a")))
    }

    func testDecodePCM() async throws {
        let url = try fixture("en.pcm")
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        try await check(.pcm16le(url), expected: Double(bytes) / 32000)
    }

    func testTextFileThrowsFFmpegError() async throws {
        let dir = try tempDir()
        let txt = dir.appendingPathComponent("not audio.txt")
        try "hello $(world) 'quoted'".write(to: txt, atomically: true, encoding: .utf8)
        do {
            _ = try await decoder().decodeToWAV(.media(txt), into: dir)
            XCTFail("expected throw")
        } catch DecodeError.ffmpeg {
        }
    }
}
