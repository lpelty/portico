import AppKit
import Foundation
import SwiftUI

// MARK: - CommentsTheme (v0.23)

/// The comment colours as CSS variables for the page and the editor: a
/// light `:root` block and a dark one under `prefers-color-scheme`, so the
/// page needs no appearance messages. Solid hex values only.
enum CommentsTheme {
    static let waitHex = ("#B86E00", "#F0B24A")
    static let waitSoftHex = ("#FFF3DE", "#3B2E16")
    static let accentHex = ("#3B6BE0", "#6B8FF2")
    static let accentSoftHex = ("#EBF0FC", "#26304A")
    /// Text on the bright `wait` highlight (an active anchor or a draft).
    static let onWaitHex = ("#FFFFFF", "#1C1C1E")

    static func css(accent: String? = nil) -> String {
        func block(_ pick: ((String, String)) -> String, _ token: (Theme.Token) -> String) -> String {
            """
              --pc-wait: \(pick(waitHex)); --pc-wait-soft: \(pick(waitSoftHex)); --pc-on-wait: \(pick(onWaitHex));
              --pc-accent: \(accent ?? pick(accentHex)); --pc-accent-soft: \(pick(accentSoftHex));
              --pc-agent: \(token(.agentAvatar)); --pc-card: \(token(.control)); --pc-border: \(token(.border));
              --pc-text: \(token(.text)); --pc-text2: \(token(.text2)); --pc-text3: \(token(.text3));
              --pc-surface: \(token(.surface)); --pc-panel: \(token(.panel));
            """
        }
        let light = block({ $0.0 }) { Theme.hex($0).light }
        let dark = block({ $0.1 }) { Theme.hex($0).dark }
        return ":root {\n\(light)\n}\n@media (prefers-color-scheme: dark) { :root {\n\(dark)\n} }\n"
    }
}
