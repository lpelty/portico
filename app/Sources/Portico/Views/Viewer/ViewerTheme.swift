import Foundation

/// v0.26 (PORT-25, ruling 13): the viewer's colour variables, from `Theme`'s
/// tokens: a light `:root` block and a dark one under `prefers-color-scheme`,
/// put in front of viewer.css when the page is built. viewer.css keeps no
/// colour of its own. The brand accent, when the gateway sent one, is the link.
enum ViewerTheme {
    /// Each variable and the token it reads.
    static let variables: [(name: String, token: Theme.Token)] = [
        ("--fg", .text), ("--fg-muted", .text3), ("--bg", .window), ("--rule", .border),
        ("--code-bg", .surface), ("--link", .accent), ("--quote", .text3),
        ("--fm-key", .text3), ("--fm-value", .text2), ("--fm-tag", .surface),
        ("--fm-wait", .wait), ("--fm-done", .working), ("--fm-stopped", .stopped), ("--fm-neutral", .idle),
    ]

    static func css(accent: String? = nil) -> String {
        func block(_ pick: (Theme.Token) -> String) -> String {
            variables.map { variable in
                let value = variable.name == "--link" ? (accent ?? pick(variable.token)) : pick(variable.token)
                return "  \(variable.name): \(value);"
            }.joined(separator: "\n")
        }
        let light = block { Theme.hex($0).light }
        let dark = block { Theme.hex($0).dark }
        return ":root {\n\(light)\n}\n@media (prefers-color-scheme: dark) { :root {\n\(dark)\n} }\n"
    }
}
