import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MLX

/// Real-ESRGAN ×4 on MLX, in process: RRDBNet (x4plus, best for photos) or SRVGGNetCompact (general-x4v3, about ten
/// times faster, for video). mlx-community's weights are already in MLX's conv layout (out, kH, kW, in), so each network
/// is a handful of functional convolutions over the weight dictionary.
final class RealESRGAN: @unchecked Sendable {
    static let scale = 4
    /// Input tiles (plus `pad` on each side) keep memory flat on large images; the padding hides seams.
    static let tile = 192, pad = 12
    private let w: [String: MLXArray]
    private let blocks: Int

    /// SRVGGNetCompact's layers: conv, PReLU, conv, PReLU, ..., conv to 3 × 4 × 4 channels.
    private let compactLayers: Int

    init(folder: URL) throws {
        w = try loadArrays(url: folder.appending(path: "model.safetensors"))
        blocks = w.keys.filter { $0.hasSuffix(".rdb1.conv1.weight") }.count
        compactLayers = blocks == 0 ? w.keys.filter { $0.hasPrefix("body.") && $0.hasSuffix(".weight") }.count : 0
        guard (blocks > 0 && w["conv_first.weight"] != nil) || compactLayers > 2 else {
            throw ImageToolError.failed("Not a Real-ESRGAN checkpoint (RRDBNet or SRVGGNetCompact).")
        }
    }

    private func conv(_ x: MLXArray, _ name: String) -> MLXArray { conv2d(x, w[name + ".weight"]!, padding: 1) + w[name + ".bias"]! }
    private func lrelu(_ x: MLXArray) -> MLXArray { maximum(x, 0.2 * x) }

    private func denseBlock(_ x: MLXArray, _ p: String) -> MLXArray {
        let x1 = lrelu(conv(x, p + ".conv1"))
        let x2 = lrelu(conv(concatenated([x, x1], axis: -1), p + ".conv2"))
        let x3 = lrelu(conv(concatenated([x, x1, x2], axis: -1), p + ".conv3"))
        let x4 = lrelu(conv(concatenated([x, x1, x2, x3], axis: -1), p + ".conv4"))
        return conv(concatenated([x, x1, x2, x3, x4], axis: -1), p + ".conv5") * 0.2 + x
    }

    private func up2(_ x: MLXArray) -> MLXArray { repeated(repeated(x, count: 2, axis: 1), count: 2, axis: 2) }

    /// [1, H, W, 3] in 0...1 to [1, 4H, 4W, 3].
    func forward(_ x: MLXArray) -> MLXArray {
        compactLayers > 0 ? forwardCompact(x) : forwardRRDB(x)
    }

    private func forwardCompact(_ x: MLXArray) -> MLXArray {
        let s = Self.scale
        var h = x.asType(w["body.0.weight"]!.dtype)
        for i in 0..<compactLayers {
            let weight = w["body.\(i).weight"]!
            if weight.ndim == 4 {
                h = conv2d(h, weight, padding: 1) + w["body.\(i).bias"]!
            } else {
                h = maximum(h, 0) + weight * minimum(h, 0)   // PReLU, one slope per channel
            }
        }
        // Pixel shuffle (PyTorch channel order c·r·r + i·r + j) in NHWC, plus the input upsampled.
        let n = h.dim(1), m = h.dim(2), c = h.dim(3) / (s * s)
        let shuffled = h.reshaped([1, n, m, c, s, s]).transposed(0, 1, 4, 2, 5, 3).reshaped([1, n * s, m * s, c])
        return shuffled + repeated(repeated(x.asType(h.dtype), count: s, axis: 1), count: s, axis: 2)
    }

    private func forwardRRDB(_ x: MLXArray) -> MLXArray {
        let x = x.asType(w["conv_first.weight"]!.dtype)
        let first = conv(x, "conv_first")
        var body = first
        for i in 0..<blocks {
            let p = "body.\(i)"
            body = denseBlock(denseBlock(denseBlock(body, p + ".rdb1"), p + ".rdb2"), p + ".rdb3") * 0.2 + body
        }
        var h = first + conv(body, "conv_body")
        h = lrelu(conv(up2(h), "conv_up1"))
        h = lrelu(conv(up2(h), "conv_up2"))
        return conv(lrelu(conv(h, "conv_hr")), "conv_last")
    }

    /// RGB floats (row-major, 0...1) of size w×h to the ×4 image, tile by tile.
    func upscale(_ rgb: [Float], width: Int, height: Int, progress: (Double) -> Void = { _ in }) -> [Float] {
        let s = Self.scale, ow = width * s
        var out = [Float](repeating: 0, count: width * s * height * s * 3)
        let src = MLXArray(rgb, [1, height, width, 3])
        let ys = Array(stride(from: 0, to: height, by: Self.tile)), xs = Array(stride(from: 0, to: width, by: Self.tile))
        var done = 0
        for y0 in ys {
            for x0 in xs {
                let y1 = min(y0 + Self.tile, height), x1 = min(x0 + Self.tile, width)
                let py0 = max(0, y0 - Self.pad), px0 = max(0, x0 - Self.pad)
                let py1 = min(height, y1 + Self.pad), px1 = min(width, x1 + Self.pad)
                let tile = clip(forward(src[0..., py0..<py1, px0..<px1, 0...]), min: 0, max: 1).asType(.float32)
                // Drop the padding, then copy the tile's rows into place.
                let crop = tile[0, ((y0 - py0) * s)..<((y1 - py0) * s), ((x0 - px0) * s)..<((x1 - px0) * s), 0...]
                let values = crop.asArray(Float.self), tw = (x1 - x0) * s
                for row in 0..<((y1 - y0) * s) {
                    let dst = ((y0 * s + row) * ow + x0 * s) * 3
                    out.replaceSubrange(dst..<(dst + tw * 3), with: values[(row * tw * 3)..<((row + 1) * tw * 3)])
                }
                done += 1
                progress(Double(done) / Double(ys.count * xs.count))
            }
        }
        return out
    }
}

extension ImageTools {
    /// The image ×4 as PNG (alpha dropped).
    static func upscale(_ image: Data, model: RealESRGAN, maxSide: Int = 1024) throws -> Data {
        let cg = try decode(image)
        guard max(cg.width, cg.height) <= maxSide else {
            throw ImageToolError.failed("Upscaling takes images up to \(maxSide) px on a side; this one is \(cg.width)×\(cg.height).")
        }
        return try png(CIImage(cgImage: try upscale(cg, model: model)), gray: false)
    }

    /// The image ×4 (alpha dropped).
    static func upscale(_ cg: CGImage, model: RealESRGAN) throws -> CGImage {
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImageToolError.unreadable }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { for c in 0..<3 { rgb[i * 3 + c] = Float(rgba[i * 4 + c]) / 255 } }
        let up = model.upscale(rgb, width: w, height: h)
        let s = RealESRGAN.scale, ow = w * s, oh = h * s
        var bytes = [UInt8](repeating: 255, count: ow * oh * 4)
        for i in 0..<(ow * oh) { for c in 0..<3 { bytes[i * 4 + c] = UInt8((up[i * 3 + c] * 255).rounded()) } }
        return try cgImage(CIImage(bitmapData: Data(bytes), bytesPerRow: ow * 4, size: CGSize(width: ow, height: oh), format: .RGBA8, colorSpace: space))
    }
}
