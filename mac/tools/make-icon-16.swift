// Hand-tuned 16 px icon for the Windows .ico (title bar, taskbar small icons): the same tile and glyph as the big
// icon (two windows joined by a bright link, a green "online" dot), drawn on whole pixels so it stays crisp.
// Usage: swift mac/tools/make-icon-16.swift out.png
import AppKit

let a = CommandLine.arguments
let n = 16
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(n)); ctx.scaleBy(x: 1, y: -1)   // draw top-down, like a pixel editor
ctx.setShouldAntialias(true)
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ al: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: al) }
func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ col: CGColor) { ctx.setFillColor(col); ctx.fill(CGRect(x: x, y: y, width: w, height: h)) }

// tile: near-black, lifted, with a light rim so it reads on a dark taskbar
let tile = CGRect(x: 0.5, y: 0.5, width: 15, height: 15)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
ctx.setFillColor(c(38, 42, 49)); ctx.fillPath()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
ctx.setStrokeColor(c(204, 217, 235, 0.80)); ctx.setLineWidth(1); ctx.strokePath()
ctx.setShouldAntialias(false)

// two windows (light outline, dark inside), joined by a bright link on the middle row
let ww = 5, top = 6, left = 2, right = n - left - ww
let rim = c(214, 224, 238), inside = c(30, 34, 40)
for x0 in [left, right] { px(x0, top, ww, ww, rim); px(x0 + 1, top + 1, ww - 2, ww - 2, inside) }
let mid = top + ww / 2
px(left + ww, mid, right - left - ww, 1, c(235, 246, 255))
px(left + 1, top + 1, 1, 1, c(52, 211, 153))   // the green "connected" dot, top-left inside the left window

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
