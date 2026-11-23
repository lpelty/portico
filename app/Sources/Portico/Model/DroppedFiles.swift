import Foundation
import UniformTypeIdentifiers

/// What a drop over a conversation holds, read from its item providers
/// (v0.28, PORT-79). A file on disk is attached where it is. A promised
/// file (a drag out of Mail, Outlook, Photos or a browser's downloads: no
/// file exists until the drop asks for it) is written into the pending
/// folder first, as a pasted image is. A folder is counted and left out.
@MainActor
enum DroppedFiles {
    /// What a drop target is asked about: files on disk, and anything that
    /// can hand over a file. Wider than what is taken: see `takes`.
    nonisolated static let types: [UTType] = [.fileURL, .item]

    /// Whether a provider is a file: one on disk, or one an app promises.
    /// A promised file comes with a file's name (a name and an extension)
    /// and is not a link. Dragged text, a link and an image out of a web
    /// page are none of these and are left alone, as before v0.28.
    nonisolated static func takes(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return true }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return false }
        guard let name = provider.suggestedName else { return false }
        let file = URL(fileURLWithPath: name)
        return !file.pathExtension.isEmpty && !file.deletingPathExtension().lastPathComponent.isEmpty
    }

    /// Whether a drop holds anything to attach: a drop target's answer.
    nonisolated static func takes(_ providers: [NSItemProvider]) -> Bool {
        providers.contains(where: takes)
    }

    struct Result: Equatable, Sendable {
        /// The files to attach, in the drop's order.
        var paths: [String] = []
        /// Folders in the drop: never attached.
        var folders = 0
        /// Files that could not be had: a promise that failed, or nowhere to keep it.
        var failed = 0
    }

    /// Begin reading every provider now, and answer when all have. `folder`
    /// is where promised files are kept (`PastedImages.pendingFolder`);
    /// `nil` (no home) fails them.
    ///
    /// A drop's providers can be read only while the drop is being handled:
    /// a read first asked for after the drop handler has returned gets
    /// nothing (v0.28.0 in a running app: the drop was accepted and no file
    /// was attached). So every read is asked for before this returns, and a
    /// drop handler calls it before it returns.
    static func begin(_ providers: [NSItemProvider], promisedInto folder: URL?) -> Task<Result, Never> {
        let reading = providers.filter(takes).map { begin($0, promisedInto: folder) }
        return Task {
            var result = Result()
            for answers in reading {
                var one = One.none
                for await answer in answers { one = answer }
                switch one {
                case .file(let path): result.paths.append(path)
                case .folder: result.folders += 1
                case .none: result.failed += 1
                }
            }
            return result
        }
    }

    /// `begin`, awaited.
    static func load(_ providers: [NSItemProvider], promisedInto folder: URL?) async -> Result {
        await begin(providers, promisedInto: folder).value
    }

    private enum One: Sendable {
        case file(String)
        case folder
        case none
    }

    /// Ask one provider for its file, now; the stream gives its one answer.
    private static func begin(_ provider: NSItemProvider, promisedInto folder: URL?) -> AsyncStream<One> {
        let (answers, continuation) = AsyncStream<One>.makeStream()
        let answer: @Sendable (One) -> Void = { one in
            continuation.yield(one)
            continuation.finish()
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? URL, url.isFileURL else { return answer(.none) }
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                answer(isFolder ? .folder : .file(url.path))
            }
        } else if let folder, provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
            // The provider writes its file to a place of its own and removes it
            // when the handler returns: the copy is made inside the handler.
            let suggested = provider.suggestedName
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { return answer(.none) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let ext = url.pathExtension
                    var name = suggested.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                    let destination = PastedImages.unique(name, ext: ext, in: folder)
                    try FileManager.default.copyItem(at: url, to: destination)
                    answer(.file(destination.path))
                } catch {
                    answer(.none)
                }
            }
        } else {
            answer(.none)
        }
        return answers
    }
}
