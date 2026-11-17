import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

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

    /// The first frame as JPEG.
    public static func thumbnail(of url: URL, maxSide: CGFloat = 512) async -> Data? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        guard let cg = try? await gen.image(at: .zero).image else { return nil }
        return CIContext().jpegRepresentation(of: CIImage(cgImage: cg), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
