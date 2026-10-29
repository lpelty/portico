import AppKit
import SwiftUI

/// What the app shows of the gateway's brand (spec section 8): the name
/// in the title bar and the About panel, the accent colour on controls,
/// the icon where the app shows one. All from `hello`; defaults are
/// "Portico" and the system accent. View-free so it can be tested.
struct BrandPresentation: Equatable {
    let brand: Brand?

    init(brand: Brand?) {
        self.brand = brand
    }

    static let defaultName = "Portico"

    var name: String {
        let trimmed = brand?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }

    /// The accent for `.tint`, or `nil` for the system accent when the
    /// gateway names none or names one the app cannot read.
    var accent: Color? {
        brand?.accent.flatMap(Self.color(hex:))
    }

    /// The brand icon, loaded from the absolute image path `brand.icon`
    /// names; `nil` when there is none or it cannot be read.
    var iconImage: NSImage? {
        guard let path = brand?.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return NSImage(contentsOfFile: expanded)
    }

    /// A CSS hex colour (`#RGB`, `#RRGGBB`, `#RRGGBBAA`, hash optional) as a
    /// `Color`; `nil` for anything else.
    static func color(hex: String) -> Color? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy(\.isHexDigit) else { return nil }
        let digits: [Character]
        switch text.count {
        case 3: digits = text.flatMap { [$0, $0] }
        case 6, 8: digits = Array(text)
        default: return nil
        }
        func channel(_ i: Int) -> Double? {
            guard let value = UInt8(String(digits[i * 2..<i * 2 + 2]), radix: 16) else { return nil }
            return Double(value) / 255.0
        }
        guard let r = channel(0), let g = channel(1), let b = channel(2) else { return nil }
        let a = digits.count == 8 ? channel(3) ?? 1 : 1
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

extension AppModel {
    /// The brand the gateway's last `hello` carried, as the views show it.
    var brand: BrandPresentation { BrandPresentation(brand: hello?.brand) }
}

// MARK: - The rounded mark (v0.7 decision 5)

/// Whether the brand icon is drawn in the macOS icon shape. A flat square
/// (opaque corners) is rounded; an image whose four corners are already
/// transparent has its own shape and is drawn as given. The same test
/// `bin/install` runs on `app_icon` (`app/Packaging/shape-app-icon.swift`):
/// the pixel one in from each corner, transparent below alpha 16.
enum BrandIconShape {
    /// The corner radius as a share of the side: the macOS icon grid's
    /// 185 on an 824-point body.
    static let cornerFraction: CGFloat = 0.22

    /// True when the image should be rounded: any corner is opaque. An
    /// image that cannot be read as pixels is drawn as given.
    static func rounds(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return !cornersAreTransparent(cgImage)
    }

    /// True when each corner pixel (one in from the edge) is nearly
    /// transparent. Reads four single pixels, not the whole image, so it
    /// is cheap enough to run each time the mark is drawn.
    static func cornersAreTransparent(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        guard w > 4, h > 4 else { return false }
        let inset = 1
        let corners = [(inset, inset), (w - 1 - inset, inset), (inset, h - 1 - inset), (w - 1 - inset, h - 1 - inset)]
        return corners.allSatisfy { x, y in
            guard let alpha = alpha(of: image, x: x, y: y) else { return false }
            return alpha < 16
        }
    }

    /// One pixel's alpha (0–255), drawn premultiplied into a 1×1 context.
    private static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8? {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var bytes: [UInt8] = [0, 0, 0, 0]
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? bytes[3] : nil
    }
}

/// The brand icon at a given side: clipped to the macOS icon shape
/// (continuous corners, radius about 22 % of the side) when its corners
/// are opaque, else as given (v0.7 decision 5). The welcome's greeting
/// mark and the sidebar header's mark both draw it.
struct BrandIcon: View {
    let image: NSImage
    let side: CGFloat

    var body: some View {
        let picture = Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
        if BrandIconShape.rounds(image) {
            picture.clipShape(RoundedRectangle(cornerRadius: side * BrandIconShape.cornerFraction, style: .continuous))
        } else {
            picture
        }
    }
}

/// The brand icon and name at the top of the sidebar, only when the
/// gateway gave an icon: without one the window title already says the name.
struct BrandHeader: View {
    let brand: BrandPresentation

    var body: some View {
        if let icon = brand.iconImage {
            HStack(spacing: 8) {
                BrandIcon(image: icon, side: 20)
                Text(brand.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(brand.name)
        }
    }
}

extension BrandPresentation {
    /// The standard About panel with the brand's name and icon, and the app's version.
    @MainActor
    func showAboutPanel(version: String) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: name,
            .applicationVersion: version,
        ]
        if let icon = iconImage {
            options[.applicationIcon] = icon
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    /// The Dock and app-switcher icon: the brand's, but only for a build
    /// with no icon of its own (`swift run`). A built Portico.app carries
    /// the icon `bin/install` made for macOS; replacing it with the raw
    /// `brand.icon` a moment after launch swapped the shaped Dock icon for
    /// a flat square (v0.5 decision 2). `brand.icon` stays the in-app mark.
    @MainActor
    func applyApplicationIcon(bundle: Bundle = .main) {
        guard Self.shouldReplaceApplicationIcon(bundleInfo: bundle.infoDictionary), let icon = iconImage else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    /// Whether the running bundle lacks an icon of its own: neither
    /// `CFBundleIconFile` (an `.icns`) nor `CFBundleIconName` (an asset
    /// catalog icon) names one.
    nonisolated static func shouldReplaceApplicationIcon(bundleInfo: [String: Any]?) -> Bool {
        for key in ["CFBundleIconFile", "CFBundleIconName"] {
            if let name = bundleInfo?[key] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return false
            }
        }
        return true
    }
}
