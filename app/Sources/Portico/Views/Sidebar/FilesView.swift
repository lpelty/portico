import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - FileNode

/// One row of the Files pane: an entry the gateway listed, or the
/// placeholder shown under a directory that has not been listed yet.
/// The placeholder's appearance is what asks the gateway for that
/// directory, so each directory is listed once, when it is first opened.
struct FileNode: Identifiable, Equatable {
    var chat: Int
    var root: String
    /// The gateway's relative path of this entry (`src/lib`, `main.py`).
    var path: String
    var name: String
    var dir: Bool
    var size: Int?
    /// `true` for the loading row under an unlisted directory; `path` is
    /// then the directory to list.
    var placeholder: Bool = false
    /// `nil` for a file (no disclosure); the listed entries, or one
    /// placeholder, for a directory.
    var children: [FileNode]?

    var id: String { "\(chat)|\(root)|\(path)|\(placeholder ? "loading" : "entry")" }

    /// The directory this node's listing lives under (the node itself for
    /// a directory, its parent for a file).
    var directoryPath: String {
        if dir || placeholder { return path }
        return (path as NSString).deletingLastPathComponent
    }
}

// MARK: - FilesView

/// The sidebar's lower half: the chat's folder as root `chat`, then the
/// deployment's roots from `hello`, each an outline listed lazily (one
/// `files.list` per directory the first time it opens). A filter field
/// narrows to what has been listed so far. A click shows a file in the
/// viewer at once (no gateway round trip); **Add to chat** and a drag
/// onto the input bar attach it to the next message.
struct FilesView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                tree
            } else {
                matches
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter files", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the filter")
            }
            Button {
                model.refreshFiles(chat: chat)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("List the open folders again")
            .disabled(model.connection != .connected)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: the outline

    private var tree: some View {
        List {
            ForEach(model.fileRoots(for: chat), id: \.name) { root in
                Section {
                    OutlineGroup(nodes(root: root.name, path: ""), children: \.children) { node in
                        row(node)
                    }
                } header: {
                    Label(root.name, systemImage: root.name == AppModel.chatRoot ? "folder.badge.person.crop" : "folder")
                        .help(root.path)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.fileRoots(for: chat).isEmpty {
                ContentUnavailableView("No folders", systemImage: "folder", description: Text("The chat's folder appears once the gateway lists the chat."))
            }
        }
    }

    /// The entries of one directory as nodes, recursing into the
    /// directories already listed; a directory not listed yet gets one
    /// placeholder whose appearance asks for it.
    private func nodes(root: String, path: String) -> [FileNode] {
        guard let entries = model.fileEntries(chat: chat, root: root, path: path) else {
            return [FileNode(chat: chat, root: root, path: path, name: "", dir: true, placeholder: true)]
        }
        return entries.map { entry in
            let childPath = AppModel.childPath(path, entry.name)
            return FileNode(
                chat: chat, root: root, path: childPath, name: entry.name, dir: entry.dir, size: entry.size,
                children: entry.dir ? nodes(root: root, path: childPath) : nil)
        }
    }

    @ViewBuilder
    private func row(_ node: FileNode) -> some View {
        if node.placeholder {
            if let refusal = model.fileListError(chat: chat, root: node.root, path: node.path) {
                // The gateway refused the listing (a link that leaves the
                // root, a directory gone): say so where the entries would
                // be; a click asks again.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(refusal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
                .help("Click to ask again")
                .onTapGesture { model.listFiles(chat: chat, root: node.root, path: node.path) }
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(model.connection == .connected ? "Listing…" : "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onAppear { model.listFiles(chat: chat, root: node.root, path: node.path) }
            }
        } else {
            FileRow(node: node, subtitle: nil)
        }
    }

    // MARK: the filter's flat list

    /// Every listed entry, in every root, whose name contains the filter.
    private var matchingNodes: [FileNode] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var found: [FileNode] = []
        for root in model.fileRoots(for: chat) {
            collect(root: root.name, path: "", needle: needle, into: &found)
        }
        return found
    }

    private func collect(root: String, path: String, needle: String, into found: inout [FileNode]) {
        guard let entries = model.fileEntries(chat: chat, root: root, path: path) else { return }
        for entry in entries {
            let childPath = AppModel.childPath(path, entry.name)
            if entry.name.lowercased().contains(needle) {
                found.append(FileNode(chat: chat, root: root, path: childPath, name: entry.name, dir: entry.dir, size: entry.size))
            }
            if entry.dir {
                collect(root: root, path: childPath, needle: needle, into: &found)
            }
        }
    }

    private var matches: some View {
        List(matchingNodes) { node in
            FileRow(node: node, subtitle: "\(node.root)/\(node.path)")
        }
        .listStyle(.sidebar)
        .overlay {
            if matchingNodes.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
    }
}

// MARK: - FileRow

/// One listed entry: icon, name, size for a file; a click shows a file
/// in the viewer; the context menu adds it to the chat, opens it
/// externally or reveals it; a drag carries its file URL.
struct FileRow: View {
    let node: FileNode
    /// Shown under the name in the filter's flat list (root and path).
    let subtitle: String?
    @EnvironmentObject private var model: AppModel

    private var absolutePath: String? {
        model.absolutePath(
            chat: node.chat, root: node.root, path: (node.path as NSString).deletingLastPathComponent, name: node.name)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(node.dir ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if !node.dir, let size = node.size {
                Text(Self.sizeText(size))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .help(absolutePath ?? node.name)
        .onTapGesture {
            guard !node.dir, let path = absolutePath else { return }
            model.openArtifact(file: path, in: node.chat)
        }
        .contextMenu { menu }
        .modifier(DragFile(path: absolutePath))
    }

    private var icon: String {
        if node.dir { return "folder" }
        switch Media.of(path: node.name) {
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .html: return "globe"
        case .pdf: return "doc.text"
        case .text: return "doc.plaintext"
        case .url: return "link"
        case .other: return "doc"
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let path = absolutePath {
            if !node.dir {
                Button("Open in viewer") { model.openArtifact(file: path, in: node.chat) }
                Button("Add to chat") { model.attach([path], to: node.chat) }
                    .help("Attach to the next message")
                Divider()
            }
            Button("Open externally") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            if node.dir {
                Divider()
                Button("List again") { model.refreshFiles(chat: node.chat) }
            }
        }
    }

    /// `1.2 KB`, `640 B`.
    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// `.draggable` with the file's URL when the row has one; the input bar's
/// drop target turns it into an attachment chip.
private struct DragFile: ViewModifier {
    let path: String?

    func body(content: Content) -> some View {
        if let path {
            content.draggable(URL(fileURLWithPath: path))
        } else {
            content
        }
    }
}
