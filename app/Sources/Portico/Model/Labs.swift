import Foundation

// v0.25 §2 (PORT-5): Settings › Labs, for features being tried out on this
// Mac. The gateway lists them in `hello.labs`; the app's own machine flag
// adds Read aloud's row when the gateway sent none for it (ruling 5).

extension AppModel {
    /// The rows Labs shows: the gateway's items, then Read aloud's when only
    /// this app turns it on (its machine flag, or an older gateway's `[voice]`).
    /// v0.26: `voice.elevenlabs` is folded into Read aloud's block, never a row of its own.
    var labItems: [LabItem] {
        var items = labs.filter { $0.key != LabItem.elevenLabsKey }
        guard !items.contains(where: { $0.key == LabItem.readAloudKey }) else { return items }
        if settings.deploymentReadAloud {
            // A v0.24 gateway turns Read aloud on in its config but sends no `labs`.
            var row = LabItem.readAloudFlag
            row.source = LabItem.olderGatewaySource
            items.insert(row, at: 0)
        } else if settings.readAloudFlag {
            items.insert(.readAloudFlag, at: 0)
        }
        return items
    }

    /// The gateway's ElevenLabs voices item, drawn inside Read aloud's block (v0.26, ruling 5).
    var elevenLabsItem: LabItem? {
        labs.first { $0.key == LabItem.elevenLabsKey }
    }
}

/// How a Labs row reads (ruling 2).
enum LabPresentation {
    /// The Settings tab titles a `home` may name.
    private static let homes: [String: SettingsTab] = [
        "general": .general, "gateway": .gateway, "mcp": .mcpServers, "mcp_servers": .mcpServers,
        "plugins": .plugins, "voice": .voice, "appearance": .appearance,
    ]

    /// The line under the item's title: where it was turned on, then where it moves when released.
    /// v0.26 (ruling 5): Read aloud's note also says where ElevenLabs voices were turned on.
    static func note(_ item: LabItem, elevenLabs: LabItem? = nil) -> String {
        var note: String
        if item.source == LabItem.readAloudFlag.source {
            note = "Turned on for this Mac"
        } else if item.source.hasPrefix("plugin:") {
            note = "Added by this Mac's plug-in “\(item.source.dropFirst("plugin:".count))” · Not part of the app"
        } else {
            note = "Turned on in \(item.source)"
        }
        if let elevenLabs {
            note += " · ElevenLabs voices turned on in \(elevenLabs.source)"
        }
        // Review N7: only a Preview feature moves anywhere when released.
        if item.tag == .preview, let home = item.home, let tab = homes[home] {
            note += " · Moves to \(tab.title) when released"
        }
        return note
    }
}
