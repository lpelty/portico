import Foundation

/// One row of Settings › General › Also show in Files.
struct ExtraFolderRow: Equatable, Sendable, Identifiable {
    var path: String
    var missing: Bool
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    /// The path with the home folder shortened to `~`.
    var shownPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// v0.19 §4.2 (`files.extra.v1`): folders a person adds to the Files pane.
/// They live in `settings.extraFolders`; the gateway keeps them per
/// connection, so they are sent again on every connect and on every change.
extension AppModel {
    var offersExtraFolders: Bool { offers(FilesRootsSet.capability) }

    /// What sits under the list: the explanation, or why Add is off.
    var extraFoldersNote: String {
        // Not said before a gateway has spoken: "needs a newer one" is for a hello that lacks it.
        hello != nil && !offersExtraFolders
            ? GeneralSettingsPresentation.extraFoldersNeedsNewerGateway
            : GeneralSettingsPresentation.extraFoldersFootnote(brand: brand.name)
    }

    /// Look at the disk for each folder in the list. Done when the list changes, a gateway
    /// connects, or Settings opens, never from a view body.
    func refreshExtraFolderChecks() {
        var checks: [String: Bool] = [:]
        for path in settings.extraFolders {
            var isDir: ObjCBool = false
            checks[path] = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        if checks != extraFolderChecks { extraFolderChecks = checks }
    }

    /// The list as Settings draws it; a folder is "Not found" by the gateway's word once it has given
    /// one, else by the last look at the disk (none yet: not missing).
    var extraFolderRows: [ExtraFolderRow] {
        settings.extraFolders.map { path in
            if let root = extraRoots.first(where: { $0.path == path }) {
                return ExtraFolderRow(path: path, missing: root.isMissing)
            }
            return ExtraFolderRow(path: path, missing: extraFolderChecks[path] == false)
        }
    }

    /// The list for a connection that is starting: nothing without the capability or without folders.
    func extraFoldersFrames() -> [ClientMessage] {
        guard offersExtraFolders, !settings.extraFolders.isEmpty else { return [] }
        return [.filesRootsSet(FilesRootsSet(paths: settings.extraFolders, id: Self.requestId()))]
    }

    func addExtraFolder(_ folder: URL) {
        guard offersExtraFolders else { return }
        let path = folder.standardizedFileURL.path
        guard !settings.extraFolders.contains(path) else { return }
        settings.extraFolders.append(path)
        refreshExtraFolderChecks()
        sendExtraFolders()
    }

    func removeExtraFolder(_ path: String) {
        guard settings.extraFolders.contains(path) else { return }
        settings.extraFolders.removeAll { $0 == path }
        refreshExtraFolderChecks()
        // Gone from the list whatever the gateway; only a gateway that keeps the list hears of it.
        if offersExtraFolders { sendExtraFolders() }
    }

    private func sendExtraFolders() {
        send(.filesRootsSet(FilesRootsSet(paths: settings.extraFolders, id: Self.requestId())))
    }
}
