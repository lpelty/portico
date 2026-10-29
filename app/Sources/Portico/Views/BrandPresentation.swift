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

/// The brand icon and name at the top of the sidebar, only when the
/// gateway gave an icon: without one the window title already says the name.
struct BrandHeader: View {
    let brand: BrandPresentation

    var body: some View {
        if let icon = brand.iconImage {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
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
