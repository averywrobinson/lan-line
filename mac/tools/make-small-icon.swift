// Small icon sizes (16–48 px) for the Windows taskbar and title bar: the cut-out tile drawn at the target size,
// lifted slightly and given a light rim so it doesn't vanish on a dark taskbar. Larger sizes use the plain cut.
// Usage: swift mac/tools/make-small-icon.swift cut-1024.png SIZE out.png
import AppKit

let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let size = CGFloat(Int(a[2])!)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
// The tile fills more of a tiny icon (less empty margin than the macOS grid): 100..924 of 1024 -> 1..size-1.
let m: CGFloat = size <= 24 ? 0.5 : 1
let tile = CGRect(x: m, y: m, width: size - 2 * m, height: size - 2 * m)
let r = tile.width * 0.225
let path = CGPath(roundedRect: tile, cornerWidth: r, cornerHeight: r, transform: nil)
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let scale = tile.width / 824
ctx.draw(src, in: CGRect(x: tile.minX - 100 * scale, y: tile.minY - 100 * scale, width: 1024 * scale, height: 1024 * scale))
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)); ctx.fill(tile)   // lift the near-black tile a little
ctx.restoreGState()
let w: CGFloat = max(1, size / 24)
let inset = tile.insetBy(dx: w / 2, dy: w / 2)
ctx.addPath(CGPath(roundedRect: inset, cornerWidth: r - w / 2, cornerHeight: r - w / 2, transform: nil))
ctx.setStrokeColor(CGColor(srgbRed: 0.80, green: 0.85, blue: 0.92, alpha: 0.75)); ctx.setLineWidth(w); ctx.strokePath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
