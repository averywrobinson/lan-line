// The Mac installer window's background: "drag Lan-Line to Applications", in the brand's dark studio look.
// Layout matches mac/tools/dmg-settings.py (640 x 400 window, icons centred at (165, 185) and (475, 185), 112 pt).
// Finder draws the icon labels itself: black in light mode, white in dark mode. A slate plate under each label keeps
// both readable on the dark canvas.
// Usage: swift mac/tools/make-dmg-background.swift out-dir   (writes bg.png and bg@2x.png)
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let W: CGFloat = 640, H: CGFloat = 400
let left = CGPoint(x: 165, y: 185), right = CGPoint(x: 475, y: 185)   // icon centres, top-left origin

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // draw with a top-left origin, like Finder's coordinates

    // Canvas and a soft blue glow between the two icons (the brand's "bridge filament").
    ctx.setFillColor(c(0x080A0F)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let glow = CGGradient(colorsSpace: cs, colors: [c(0x93C5FD, 0.16), c(0x93C5FD, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: left.y), startRadius: 0,
                           endCenter: CGPoint(x: W / 2, y: left.y), endRadius: 260, options: [])

    // Arrow from the app to Applications.
    let y = left.y, x0 = left.x + 82, x1 = right.x - 82
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(c(0x93C5FD, 0.95)); ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.strokePath()
    ctx.move(to: CGPoint(x: x1 - 14, y: y - 11)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.addLine(to: CGPoint(x: x1 - 14, y: y + 11))
    ctx.strokePath()

    // Label plates under both icons (Finder's own label text sits on these).
    for p in [left, right] {
        let plate = CGRect(x: p.x - 66, y: p.y + 62, width: 132, height: 24)
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(c(0x64748B, 0.92)); ctx.fillPath()
    }

    // Text, drawn through AppKit in a flipped graphics context.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: UInt32, y: CGFloat) {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: NSColor(cgColor: c(color))!, .paragraphStyle: para]
        (s as NSString).draw(in: CGRect(x: 24, y: y, width: W - 48, height: size * 1.6), withAttributes: attrs)
    }
    text("Drag Lan-Line to Applications", size: 20, weight: .semibold, color: 0xF8FAFC, y: 46)
    // Kept above y 368: a Finder path bar (if the user has one on) covers the bottom ~24 pt of the window.
    text("Beta builds aren't signed yet. On first open, if macOS can't verify Lan-Line:", size: 12, weight: .regular, color: 0x94A3B8, y: 322)
    text("System Settings → Privacy & Security → Open Anyway", size: 12, weight: .medium, color: 0xE2E8F0, y: 341)
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: W, height: H)   // 72 dpi at 1x, 144 dpi at 2x
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: outDir.appendingPathComponent("bg.png"))
try! render(scale: 2).write(to: outDir.appendingPathComponent("bg@2x.png"))
