import CoreImage
import CoreML
import Foundation
@preconcurrency import Vision

public enum ImageToolError: Error, LocalizedError, Equatable {
    case unreadable, noSubject, noDepthModel, noUpscaler, failed(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read; send PNG, JPEG, HEIC or WebP."
        case .noSubject: "No foreground subject was found in the image."
        case .noDepthModel: "No depth model is downloaded. Download Depth Anything V2 small in Models."
        case .noUpscaler: "No upscaling model is downloaded. Download Real-ESRGAN x4plus in Models."
        case .failed(let m): m
        }
    }
}

/// Image to image without generation: subject cut-outs and masks (macOS Vision's built-in model, nothing to
/// download) and depth maps (Depth Anything V2 through Core ML).
public enum ImageTools {
    public enum Cutout: String, Sendable, CaseIterable {
        /// The subject on a transparent background (PNG with alpha).
        case cutout
        /// White where the subject is, black elsewhere (grayscale PNG).
        case mask
    }

    public static func cutout(_ image: Data, output: Cutout) throws -> Data {
        let handler = VNImageRequestHandler(data: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { throw ImageToolError.unreadable }
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw ImageToolError.noSubject }
        let buffer: CVPixelBuffer
        do {
            buffer = output == .cutout
                ? try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
                : try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        } catch { throw ImageToolError.failed("Vision could not build the \(output.rawValue): \(error.localizedDescription)") }
        return try png(CIImage(cvPixelBuffer: buffer), gray: output == .mask)
    }

    /// The `.mlpackage` inside a downloaded depth model folder.
    static func depthPackage(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.pathExtension == "mlpackage" { return url }
        return nil
    }

    /// Compiles the package once (next to it, as `.mlmodelc`) and loads it.
    static func loadDepthModel(folder: URL) throws -> VNCoreMLModel {
        guard let package = depthPackage(in: folder) else { throw ImageToolError.noDepthModel }
        let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let temp = try MLModel.compileModel(at: package)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: temp, to: compiled)
        }
        return try VNCoreMLModel(for: MLModel(contentsOf: compiled))
    }

    /// Relative depth at the input's size, near = white, as an 8-bit grayscale PNG.
    static func depth(_ image: Data, model: VNCoreMLModel) throws -> Data {
        try png(CIImage(cgImage: try depth(decode(image), model: model)), gray: true)
    }

    /// Relative depth at the image's size, near = white (grayscale).
    static func depth(_ image: CGImage, model: VNCoreMLModel) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        do { try handler.perform([request]) } catch { throw ImageToolError.unreadable }
        guard let out = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            throw ImageToolError.failed("The depth model returned no image.")
        }
        // Depth Anything gives unscaled inverse depth; stretch this image's range to 0...1 before resizing back.
        let normalized = try stretch(out)
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: CGFloat(image.width) / normalized.extent.width,
                                                                  y: CGFloat(image.height) / normalized.extent.height))
        return try cgImage(scaled)
    }

    /// White where the subject is, black elsewhere (all black when Vision finds no subject, as in an empty video frame).
    static func mask(_ image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { throw ImageToolError.unreadable }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) else {
            return try cgImage(CIImage(color: .black).cropped(to: rect))
        }
        return try cgImage(CIImage(cvPixelBuffer: buffer))
    }

    /// One context for every conversion (they are expensive to make and safe to share).
    static let context = CIContext()

    /// Decoded with its EXIF orientation applied.
    static func decode(_ data: Data) throws -> CGImage {
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ImageToolError.unreadable }
        return try cgImage(ci)
    }

    static func cgImage(_ image: CIImage) throws -> CGImage {
        guard let cg = context.createCGImage(image, from: image.extent.integral) else { throw ImageToolError.failed("Could not render the image.") }
        return cg
    }

    /// One-channel half or float buffer to a 0...1 CIImage.
    private static func stretch(_ buffer: CVPixelBuffer) throws -> CIImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ImageToolError.failed("The depth map is empty.") }
        var values = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let p = (base + y * row).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { values[y * w + x] = Float(p[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let p = (base + y * row).assumingMemoryBound(to: Float.self)
                for x in 0..<w { values[y * w + x] = p[x] }
            }
        case let f: throw ImageToolError.failed("Unexpected depth map format \(f).")
        }
        let lo = values.min() ?? 0, span = max((values.max() ?? 1) - lo, 1e-6)
        let bytes = values.map { UInt8(max(0, min(255, (($0 - lo) / span * 255).rounded()))) }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8,
                       colorSpace: CGColorSpaceCreateDeviceGray())
    }

    static func png(_ image: CIImage, gray: Bool) throws -> Data {
        let ctx = context
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = ctx.pngRepresentation(of: image, format: gray ? .L8 : .RGBA8, colorSpace: space) else {
            throw ImageToolError.failed("Could not encode the result as PNG.")
        }
        return data
    }
}
