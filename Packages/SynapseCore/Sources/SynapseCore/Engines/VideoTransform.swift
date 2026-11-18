import AVFoundation
import CoreImage
import Foundation

/// What `POST /v1/videos/transform` and Video → Transform do to every frame.
public enum VideoOperation: String, Sendable, CaseIterable {
    /// Depth Anything per frame: near is white.
    case depth
    /// Vision's subject mask per frame: the subject white, the rest black.
    case mask
    /// Real-ESRGAN ×4 per frame (general-x4v3 when downloaded: about ten times faster than x4plus).
    case upscale
}

/// Frame by frame: decode, transform, encode H.264 at the source's timing, then put the source's audio back.
enum VideoTransform {
    static let maxSeconds = 60.0

    static func run(input: URL, output: URL, scale: Int = 1, frame: (CGImage) throws -> CGImage,
                    progress: @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImageToolError.failed("The file has no video track macOS can read; use MP4 or MOV (H.264 or HEVC).")
        }
        let seconds = try await asset.load(.duration).seconds
        guard seconds <= maxSeconds else { throw ImageToolError.failed("Videos up to \(Int(maxSeconds)) seconds are transformed; this one is \(Int(seconds)) s.") }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let orientation = orientation(of: transform)
        let upright = orientation == .right || orientation == .left ? CGSize(width: natural.height, height: natural.width) : natural
        // H.264 wants even dimensions.
        let outW = (Int(upright.width) * scale) & ~1, outH = (Int(upright.height) * scale) & ~1

        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        frames.alwaysCopiesSampleData = false
        reader.add(frames)
        guard reader.startReading() else { throw reader.error ?? ImageToolError.unreadable }

        let videoOnly = output.deletingLastPathComponent().appending(path: "video-only-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: videoOnly) }
        let writer = try AVAssetWriter(outputURL: videoOnly, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, outW * outH * 6)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ImageToolError.failed("Could not start writing the video.") }
        writer.startSession(atSourceTime: .zero)

        while let sample = frames.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let source = try ImageTools.cgImage(CIImage(cvPixelBuffer: pixels).oriented(orientation))
            let result = CIImage(cgImage: try frame(source))
            let fitted = result.transformed(by: CGAffineTransform(scaleX: CGFloat(outW) / result.extent.width, y: CGFloat(outH) / result.extent.height))
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? ImageToolError.failed("The video writer stopped.") }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let out else { throw ImageToolError.failed("Out of video frame buffers.") }
            ImageTools.context.render(fitted, to: out)
            guard adaptor.append(out, withPresentationTime: time) else { throw writer.error ?? ImageToolError.failed("A frame could not be written.") }
            if seconds > 0 { progress(min(1, time.seconds / seconds)) }
        }
        if reader.status == .failed { throw reader.error ?? ImageToolError.unreadable }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ImageToolError.failed("The video could not be finished.") }
        try await addAudio(from: asset, to: videoOnly, output: output)
    }

    /// The new video with the source's sound (passthrough, nothing re-encoded); just the video when there is none.
    private static func addAudio(from source: AVURLAsset, to video: URL, output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let audio = try await source.loadTracks(withMediaType: .audio).first else {
            try FileManager.default.moveItem(at: video, to: output)
            return
        }
        let mix = AVMutableComposition()
        let made = AVURLAsset(url: video)
        guard let madeTrack = try await made.loadTracks(withMediaType: .video).first,
              let v = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            try FileManager.default.moveItem(at: video, to: output)
            return
        }
        let range = CMTimeRange(start: .zero, duration: try await made.load(.duration))
        try v.insertTimeRange(range, of: madeTrack, at: .zero)
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: min(range.duration, try await source.load(.duration))), of: audio, at: .zero)
        guard let export = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough) else {
            try FileManager.default.moveItem(at: video, to: output)
            return
        }
        try await export.export(to: output, as: .mp4)
    }

    /// The rotation a phone video records in its transform, as an image orientation.
    private static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}
