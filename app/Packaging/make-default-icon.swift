// Draws Portico's default app icon (1024×1024 PNG) with CoreGraphics only.
// Run once from the repo root and commit the result:
//   swift app/Packaging/make-default-icon.swift app/Packaging/AppIcon.png
// bin/install uses that PNG when the config sets no brand.app_icon.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// The macOS icon grid: an 824-point rounded square centred on the canvas, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x2F5BD8))
ctx.fillPath()
ctx.restoreGState()

// Accent-blue gradient, lighter at the top.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space, colors: [rgb(0x5B8BFF), rgb(0x3B6EF5), rgb(0x2147B8)] as CFArray,
    locations: [0, 0.45, 1])!
ctx.drawLinearGradient(
    gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// The mark: a portico — pediment, entablature, four columns, a stepped base. White, slightly translucent.
ctx.setFillColor(rgb(0xFFFFFF, 0.96))
let pediment = CGMutablePath()
pediment.move(to: CGPoint(x: 262, y: 650))
pediment.addLine(to: CGPoint(x: 512, y: 770))
pediment.addLine(to: CGPoint(x: 762, y: 650))
pediment.closeSubpath()
ctx.addPath(pediment)
ctx.fillPath()
ctx.fill(CGRect(x: 262, y: 612, width: 500, height: 26))  // entablature

let columnWidth: CGFloat = 52
let left: CGFloat = 300, right: CGFloat = 724
for i in 0..<4 {
    let x = left + (right - left - columnWidth) * CGFloat(i) / 3
    ctx.fill(CGRect(x: x, y: 330, width: columnWidth, height: 264))
}
ctx.fill(CGRect(x: 262, y: 298, width: 500, height: 22))  // stylobate
ctx.fill(CGRect(x: 236, y: 264, width: 552, height: 22))  // lower step

guard let image = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not write \(out)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print(out)
