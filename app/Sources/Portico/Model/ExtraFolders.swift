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
        offersExtraFolders
            ? GeneralSettingsPresentation.extraFoldersFootnote(brand: brand.name)
            : GeneralSettingsPresentation.extraFoldersNeedsNewerGateway
    }

    /// The list as Settings draws it; a folder is "Not found" by the gateway's word once it has given
    /// one, else by a look at the disk.
    var extraFolderRows: [ExtraFolderRow] {
        settings.extraFolders.map { path in
            if let root = extraRoots.first(where: { $0.path == path }) {
                return ExtraFolderRow(path: path, missing: root.isMissing)
            }
            var isDir: ObjCBool = false
            let there = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            return ExtraFolderRow(path: path, missing: !there)
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
        sendExtraFolders()
    }

    func removeExtraFolder(_ path: String) {
        guard offersExtraFolders, settings.extraFolders.contains(path) else { return }
        settings.extraFolders.removeAll { $0 == path }
        sendExtraFolders()
    }

    private func sendExtraFolders() {
        send(.filesRootsSet(FilesRootsSet(paths: settings.extraFolders, id: Self.requestId())))
    }
}
