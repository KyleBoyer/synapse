// Draws the DMG window background. Usage: swift scripts/dmg/make-background.swift scripts/dmg
// Writes background.png (640x400) and background@2x.png; dmgbuild combines them. Icon centers match settings.py.
import AppKit

let W: CGFloat = 640, H: CGFloat = 400
let appCenter = CGPoint(x: 160, y: 190), appsCenter = CGPoint(x: 480, y: 190)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

// Finder draws icon labels black in Light and white in Dark, so the field stays mid-luminance to read in both.
let top = (r: 124.0, g: 100.0, b: 214.0), bottom = (r: 146.0, g: 104.0, b: 214.0)

func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}
for col in [top, bottom] {
    let l = luminance(col.r, col.g, col.b)
    let onWhite = 1.05 / (l + 0.05), onBlack = (l + 0.05) / 0.05
    precondition(min(onWhite, onBlack) >= 4, "labels would be hard to read: \(onWhite), \(onBlack)")
}

func render(scale: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, like Finder's icon positions.
    ctx.scaleBy(x: scale, y: -scale); ctx.translateBy(x: 0, y: -H)

    let field = CGGradient(colorsSpace: cs, colors: [c(top.r, top.g, top.b), c(bottom.r, bottom.g, bottom.b)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(field, start: .zero, end: CGPoint(x: W, y: H), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [c(255, 255, 255, 0.05), c(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: 120), startRadius: 0, endCenter: CGPoint(x: W / 2, y: 120), endRadius: 340, options: [])

    // A faint net in the corners, echoing the app icon.
    ctx.setLineCap(.round)
    let nodes: [CGPoint] = [CGPoint(x: 28, y: 46), CGPoint(x: 86, y: 22), CGPoint(x: 70, y: 92), CGPoint(x: 572, y: 330),
                            CGPoint(x: 616, y: 372), CGPoint(x: 548, y: 386), CGPoint(x: 604, y: 302)]
    let links = [(0, 1), (0, 2), (1, 2), (3, 4), (3, 5), (4, 5), (3, 6), (4, 6)]
    ctx.setStrokeColor(c(255, 255, 255, 0.10)); ctx.setLineWidth(1.5)
    for (a, b) in links { ctx.move(to: nodes[a]); ctx.addLine(to: nodes[b]) }
    ctx.strokePath()
    ctx.setFillColor(c(255, 255, 255, 0.16))
    for p in nodes { ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) }

    // Arrow from the app to Applications.
    let y = appCenter.y, x0 = appCenter.x + 96, x1 = appsCenter.x - 96
    ctx.setStrokeColor(c(255, 255, 255, 0.9)); ctx.setLineWidth(5); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.move(to: CGPoint(x: x1 - 16, y: y - 16)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.addLine(to: CGPoint(x: x1 - 16, y: y + 16))
    ctx.strokePath()

    // Caption, drawn with AppKit in a flipped context.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                .foregroundColor: NSColor.white.withAlphaComponent(0.92), .paragraphStyle: style]
    NSAttributedString(string: "Drag Synapse onto Applications to install", attributes: attrs)
        .draw(in: CGRect(x: 0, y: 330, width: W, height: 24))
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: W, height: H)  // 72 dpi at 1x, 144 at 2x
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try render(scale: 1).write(to: dir.appending(path: "background.png"))
try render(scale: 2).write(to: dir.appending(path: "background@2x.png"))
