import Foundation

/// v0.26.4 (C1, D3): what diagnostics write for a viewer's artifact id. A
/// gateway artifact's id (`art-…`) is opaque and kept; every other id carries
/// what the person opened (`local:<path>`, `local:<URL>`, `space:<file stem>`),
/// so it becomes a token by kind, numbered in the order first seen and the
/// same for the same id while the app runs: `local-1`, `link-2`, `space-3`.
/// Used by the trace's viewer line and the recording's `viewer` event alike.
@MainActor
enum ArtifactToken {
    private static var tokens: [String: String] = [:]
    private static var count = 0

    static func of(_ id: String?) -> String? {
        guard let id else { return nil }
        if id.hasPrefix("art-") { return id }
        if let made = tokens[id] { return made }
        count += 1
        let made = "\(kind(of: id))-\(count)"
        tokens[id] = made
        return made
    }

    private static func kind(of id: String) -> String {
        if id.hasPrefix(AppModel.spaceArtifactPrefix) { return "space" }
        if id.hasPrefix(AppModel.localArtifactPrefix) {
            let rest = id.dropFirst(AppModel.localArtifactPrefix.count)
            return rest.hasPrefix("/") ? "local" : "link"
        }
        return "other"
    }
}
