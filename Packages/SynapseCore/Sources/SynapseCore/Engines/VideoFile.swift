import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Small AVFoundation helpers for generated videos: a solid-color MP4 (mock engine and tests) and a JPEG thumbnail.
public enum VideoFile {
    public static func writeSolidColor(to url: URL, width: Int, height: Int, frames: Int, fps: Int,
                                       rgb: (Double, Double, Double) = (0.45, 0.3, 0.9)) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        let image = CIImage(color: CIColor(red: rgb.0, green: rgb.1, blue: rgb.2))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CIContext().render(image, to: buffer)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// An MP4 (H.264, plus AAC when `audio` is given) from an animated image (stable-diffusion.cpp writes WebP) and a WAV.
    static func encode(frames source: URL, fps: Int, audio: URL?, to url: URL) async throws {
        guard let images = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(images) > 0,
              let first = CGImageSourceCreateImageAtIndex(images, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let width = first.width, height = first.height
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)
        var reader: AVAssetReader?, readerOutput: AVAssetReaderTrackOutput?, sound: AVAssetWriterInput?
        let soundtrack = audio.map { AVURLAsset(url: $0) }
        if let soundtrack, let track = try await soundtrack.loadTracks(withMediaType: .audio).first {
            let r = try AVAssetReader(asset: soundtrack)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            r.add(out)
            let format = try await track.load(.formatDescriptions).first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format?.mSampleRate ?? 32000,
                AVNumberOfChannelsKey: format?.mChannelsPerFrame ?? 2,
            ])
            writer.add(input)
            guard r.startReading() else { throw r.error ?? CocoaError(.fileReadUnknown) }
            reader = r; readerOutput = out; sound = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        var frame = 0, videoDone = false, audioDone = sound == nil
        let count = CGImageSourceGetCount(images)
        // The writer interleaves the two tracks, so feed whichever input is ready until both are finished.
        while !(videoDone && audioDone) {
            var fed = false
            if !videoDone, video.isReadyForMoreMediaData {
                if frame < count, let image = CGImageSourceCreateImageAtIndex(images, frame, nil) {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                    guard let buffer else { throw CocoaError(.fileWriteUnknown) }
                    context.render(CIImage(cgImage: image), to: buffer)
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                    frame += 1
                } else { video.markAsFinished(); videoDone = true }
                fed = true
            }
            if !audioDone, let sound, sound.isReadyForMoreMediaData {
                if let sample = readerOutput?.copyNextSampleBuffer() { sound.append(sample) } else { sound.markAsFinished(); audioDone = true }
                fed = true
            }
            if !fed { try await Task.sleep(for: .milliseconds(2)) }
        }
        reader?.cancelReading()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// `count` frames spread evenly through the video (the middle of each equal slice), as JPEG.
    public static func frames(of url: URL, count: Int, maxSide: CGFloat = 448) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        let ctx = CIContext(), sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var out: [Data] = []
        for i in 0..<count {
            let t = CMTime(seconds: seconds * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let d = ctx.jpegRepresentation(of: CIImage(cgImage: try await gen.image(at: t).image), colorSpace: sRGB) { out.append(d) }
        }
        return out
    }

    /// The first frame as JPEG.
    public static func thumbnail(of url: URL, maxSide: CGFloat = 512) async -> Data? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        guard let cg = try? await gen.image(at: .zero).image else { return nil }
        return CIContext().jpegRepresentation(of: CIImage(cgImage: cg), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
