import Foundation
import UniformTypeIdentifiers

/// What a drop over a conversation holds, read from its item providers
/// (v0.28, PORT-79). A file on disk is attached where it is. A promised
/// file (a drag out of Mail, Outlook, Photos or a browser's downloads: no
/// file exists until the drop asks for it) is written into the pending
/// folder first, as a pasted image is. A folder is counted and left out.
@MainActor
enum DroppedFiles {
    /// What the conversation takes: files on disk, and anything that can
    /// hand over a file.
    nonisolated static let types: [UTType] = [.fileURL, .item]

    struct Result: Equatable, Sendable {
        /// The files to attach, in the drop's order.
        var paths: [String] = []
        /// Folders in the drop: never attached.
        var folders = 0
        /// Items that gave no file: a promise that failed, or nowhere to keep it.
        var failed = 0
    }

    /// Read every provider. `folder` is where promised files are kept
    /// (`PastedImages.pendingFolder`); `nil` (no home) fails them.
    static func load(_ providers: [NSItemProvider], promisedInto folder: URL?) async -> Result {
        var result = Result()
        for provider in providers {
            switch await load(provider, promisedInto: folder) {
            case .file(let path): result.paths.append(path)
            case .folder: result.folders += 1
            case .none: result.failed += 1
            }
        }
        return result
    }

    private enum One: Sendable {
        case file(String)
        case folder
        case none
    }

    private static func load(_ provider: NSItemProvider, promisedInto folder: URL?) async -> One {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let url = await fileURL(of: provider), url.isFileURL else { return .none }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isFolder ? .folder : .file(url.path)
        }
        guard let folder, provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) else { return .none }
        return await promised(provider, into: folder)
    }

    private static func fileURL(of provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// The provider writes its file to a place of its own and removes it
    /// when the handler returns: the copy is made inside the handler.
    private static func promised(_ provider: NSItemProvider, into folder: URL) async -> One {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: .none) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let ext = url.pathExtension
                    var name = suggested.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                    let destination = PastedImages.unique(name, ext: ext, in: folder)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: .file(destination.path))
                } catch {
                    continuation.resume(returning: .none)
                }
            }
        }
    }
}
