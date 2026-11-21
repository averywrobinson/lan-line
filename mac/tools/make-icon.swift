// Cuts the brand icon (assets/app-icon-1024.png: a glass tile on a dark square) out onto the macOS
// icon grid: the tile scaled to 824 px, centred in 1024, outside made transparent.
// Usage: swift mac/tools/make-icon.swift assets/app-icon-1024.png out.png
import AppKit

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = args[2]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// In the source the tile's rim runs from x/y 194 to 830 (measured on the 1024 px brand PNG).
let tileInSource = CGRect(x: 194, y: 194, width: 636, height: 636)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let scale = tile.width / tileInSource.width
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 0.225 * 824, cornerHeight: 0.225 * 824, transform: nil))
ctx.clip()
// Draw the whole source so the tile lands on `tile` (CG's origin is bottom-left; the tile is centred, so y mirrors cleanly).
ctx.draw(src, in: CGRect(x: tile.minX - tileInSource.minX * scale, y: tile.minY - tileInSource.minY * scale,
                         width: 1024 * scale, height: 1024 * scale))
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
