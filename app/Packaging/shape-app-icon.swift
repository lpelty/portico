// Puts a deployment's app icon on the macOS icon grid, with CoreGraphics only.
//   swift app/Packaging/shape-app-icon.swift <in.png> <out.png>
// make-app.sh runs it on brand.app_icon before making the .icns.
//
// A full-bleed square image becomes an 824-point body with continuous rounded
// corners, centred on a 1024×1024 canvas (100-point margin), with a soft drop
// shadow — the shape every macOS app icon has. An image whose four corners are
// already transparent is shaped already: it is copied as given. Prints "shaped"
// or "as given" on stdout.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("shape-app-icon: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else { fail("usage: shape-app-icon.swift <in.png> <out.png>") }
let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("\(input) is not an image") }

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// True when each corner pixel is (nearly) transparent: the image has its own shape.
func cornersAreTransparent(_ image: CGImage) -> Bool {
    let w = image.width, h = image.height
    guard w > 4, h > 4,
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return false }
    let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    let inset = 1
    let corners = [(inset, inset), (w - 1 - inset, inset), (inset, h - 1 - inset), (w - 1 - inset, h - 1 - inset)]
    return corners.allSatisfy { x, y in pixels[(y * w + x) * 4 + 3] < 16 }
}

if cornersAreTransparent(image) {
    let fm = FileManager.default
    if fm.fileExists(atPath: output) { try? fm.removeItem(atPath: output) }
    do { try fm.copyItem(atPath: input, toPath: output) } catch { fail("could not write \(output)") }
    print("as given")
    exit(0)
}

if image.width != 1024 || image.height != 1024 {
    FileHandle.standardError.write(
        Data("shape-app-icon: warning: \(input) is \(image.width)x\(image.height); a 1024x1024 PNG is expected, it is scaled\n".utf8))
}

let size = 1024
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("no context") }
ctx.interpolationQuality = .high

/// A rounded rectangle with continuous (curvature-smooth) corners, as macOS draws app icons.
/// Figma's corner-smoothing construction at 60% smoothing (the iOS/macOS look): each corner is a
/// short circular arc of `radius` with a cubic on each side that eases it into the straight edge,
/// so a corner spans 1.6 radii along each edge instead of one.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
    let r = min(radius, min(rect.width, rect.height) / 2 / (1 + smoothing))
    let p = (1 + smoothing) * r                          // how far along each edge the corner reaches
    let arcMeasure = 90 * (1 - smoothing)                // degrees of true arc in the middle
    let arcSection = sin(rad(arcMeasure / 2)) * r * sqrt(2)
    let alpha = (90 - arcMeasure) / 2
    let beta = 45 * smoothing
    let c = r * tan(rad(alpha / 2)) * cos(rad(beta))
    let d = c * tan(rad(beta))
    let b = (p - arcSection - c - d) / 3
    let a = 2 * b
    // The arc as one cubic: centre (r, r) from the corner, from 45°+m/2 down to 45°-m/2.
    let phi1 = rad(45 + arcMeasure / 2), phi2 = rad(45 - arcMeasure / 2)
    let k = 4 / 3 * tan(rad(arcMeasure) / 4) * r
    let arcStart = (r - r * cos(phi1), r - r * sin(phi1))
    let arcEnd = (r - r * cos(phi2), r - r * sin(phi2))
    let arcC1 = (arcStart.0 - k * sin(phi1), arcStart.1 + k * cos(phi1))
    let arcC2 = (arcEnd.0 + k * sin(phi2), arcEnd.1 - k * cos(phi2))

    let path = CGMutablePath()
    // One corner, in offsets from the bounding corner (cx, cy): `along` the edge the path arrives
    // on, `away` from it. (sx, sy) point from the corner into the rectangle.
    func corner(_ cx: CGFloat, _ cy: CGFloat, _ sx: CGFloat, _ sy: CGFloat, horizontalFirst: Bool) {
        func at(_ o: (CGFloat, CGFloat)) -> CGPoint {
            horizontalFirst
                ? CGPoint(x: cx + sx * o.0, y: cy + sy * o.1)
                : CGPoint(x: cx + sx * o.1, y: cy + sy * o.0)
        }
        path.addLine(to: at((p, 0)))
        path.addCurve(to: at(arcStart), control1: at((p - a, 0)), control2: at((p - a - b, 0)))
        path.addCurve(to: at(arcEnd), control1: at(arcC1), control2: at(arcC2))
        path.addCurve(to: at((0, p)), control1: at((0, p - a - b)), control2: at((0, p - a)))
    }
    path.move(to: CGPoint(x: rect.minX + p, y: rect.maxY))
    corner(rect.maxX, rect.maxY, -1, -1, horizontalFirst: true)   // top right, arriving along the top edge
    corner(rect.maxX, rect.minY, -1, 1, horizontalFirst: false)   // bottom right, arriving along the right edge
    corner(rect.minX, rect.minY, 1, 1, horizontalFirst: true)     // bottom left, arriving along the bottom edge
    corner(rect.minX, rect.maxY, 1, -1, horizontalFirst: false)   // top left, arriving along the left edge
    path.closeSubpath()
    return path
}

// The macOS icon grid: an 824-point body centred on the canvas, corner radius about 185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = continuousRoundedRect(tile, radius: 185)

// The body casts the shadow; the image is clipped to it inside one transparency layer so the
// shadow follows the shape and no fill colour shows at the edge.
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -12), blur: 28,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(shape)
ctx.clip()
ctx.draw(image, in: tile)
ctx.endTransparencyLayer()
ctx.restoreGState()

guard let shaped = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("could not write \(output)") }
CGImageDestinationAddImage(dest, shaped, nil)
guard CGImageDestinationFinalize(dest) else { fail("could not write \(output)") }
print("shaped")
