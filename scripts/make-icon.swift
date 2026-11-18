// Draws the app icon. `swift scripts/make-icon.swift Synapse/AppIcon.icon/Assets/network.png --layer` writes the
// foreground layer of the Icon Composer icon (the system draws the shape, background gradient, glass and shadow).
// Without --layer it draws a flat 1024 px preview with its own background.
import AppKit
let layerOnly = CommandLine.arguments.contains("--layer")
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }
// macOS icon grid: 824pt body at 100pt inset, soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
if layerOnly {
    // The icon shape is full bleed in Icon Composer, so grow the net to keep its share of the 824 pt body.
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 1024 / 824, y: 1024 / 824); ctx.translateBy(x: -512, y: -512)
} else {
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(c(30, 27, 75)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [c(49, 46, 129), c(109, 40, 217), c(219, 39, 119)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [c(255, 255, 255, 0.18), c(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 430, options: [])
}
// Three layers: 3 -> 4 -> 2. Few enough nodes to read at 16 px.
let xs: [CGFloat] = [292, 512, 732]
func column(_ n: Int, _ x: CGFloat, gap: CGFloat) -> [CGPoint] {
    (0..<n).map { CGPoint(x: x, y: 512 + (CGFloat($0) - CGFloat(n - 1) / 2) * gap) }
}
let layers = [column(3, xs[0], gap: 190), column(4, xs[1], gap: 150), column(2, xs[2], gap: 210)]
ctx.setLineCap(.round)
for (a, b) in zip(layers, layers.dropFirst()) {
    for p in a { for q in b {
        ctx.setStrokeColor(c(255, 255, 255, 0.42)); ctx.setLineWidth(14)
        ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()
    } }
}
// One active path, brighter, like a signal crossing the net.
ctx.setStrokeColor(c(255, 255, 255, 1)); ctx.setLineWidth(20)
ctx.move(to: layers[0][1]); ctx.addLine(to: layers[1][2]); ctx.addLine(to: layers[2][1]); ctx.strokePath()
for (li, layer) in layers.enumerated() {
    for (i, p) in layer.enumerated() {
        let active = (li == 0 && i == 1) || (li == 1 && i == 2) || (li == 2 && i == 1)
        let r: CGFloat = active ? 52 : 42
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: c(20, 10, 60, 0.35))
        ctx.setFillColor(c(255, 255, 255, active ? 1 : 0.9))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
}
ctx.restoreGState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
