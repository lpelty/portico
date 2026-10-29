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
            HStack(spacing: 6) {
                SidebarSectionLabel("Files")
                Spacer(minLength: 0)
                HeaderIcon(systemName: "magnifyingglass", help: "Find a file (⌘P)") {
                    model.quickOpenShown = true
                }
                HeaderIcon(systemName: "arrow.clockwise", help: "List the open folders again") {
                    model.refreshFiles(chat: chat)
                }
                .disabled(model.connection != .connected)
                HeaderIcon(
                    systemName: model.documentMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: model.documentMode ? "Back to the conversation (⌘⇧F)" : "Open the document view (⌘⇧F)"
                ) {
                    model.toggleDocumentView()
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 6)
            .padding(.horizontal, 16)
            FilesTabSwitch(selection: $model.filesTab)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            switch model.filesTab {
            case .folder:
                header
                if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                    tree
                } else {
                    matches
                }
            case .bookmarks:
                BookmarksView(chat: chat)
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
                .buttonStyle(.hover)
                .foregroundStyle(.secondary)
                .help("Clear the filter")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: the outline

    private var tree: some View {
        FileTree(chat: chat)
    }

    // MARK: the filter's flat list

    /// Every listed entry, in every root, whose name contains the filter.
    private var matchingNodes: [FileNode] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var found: [FileNode] = []
        for root in model.browsableRoots(for: chat) {
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

// MARK: - FileTree

/// The chat's roots as outlines, each directory listed lazily the first
/// time it opens. Shared by the sidebar's Folder tab (F1) and the
/// document view's tree (F3); a file's click goes where the person is
/// looking (`AppModel.reveal`). Drawn as a flat list rather than an
/// `OutlineGroup` so deep folders can indent less (`indent(depth:)`) and
/// keep their names on screen; a name that still does not fit is cut in
/// the middle, and hovering shows the whole path.
struct FileTree: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel
    /// Open directories, as `root|path`.
    @State private var expanded: Set<String> = []

    /// One drawn line: an entry or a directory's placeholder, and how deep it sits.
    struct Line: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.id }
    }

    /// Full steps for the first four levels, then small ones, so a file
    /// eight folders down still has room for its name.
    static func indent(depth: Int) -> CGFloat {
        CGFloat(min(depth, 4)) * 14 + CGFloat(max(0, depth - 4)) * 6
    }

    var body: some View {
        List {
            ForEach(model.browsableRoots(for: chat), id: \.name) { root in
                Section {
                    ForEach(lines(root: root.name, path: "", depth: 0)) { line in
                        row(line)
                    }
                } header: {
                    Label(root.name, systemImage: root.name == AppModel.chatRoot ? "folder.badge.person.crop" : "folder")
                        .help(root.path)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.browsableRoots(for: chat).isEmpty {
                ContentUnavailableView("No folders", systemImage: "folder", description: Text("The chat's folder appears once the gateway lists the chat."))
            }
        }
    }

    private func key(_ root: String, _ path: String) -> String { "\(root)|\(path)" }

    /// The entries of one directory, followed by the contents of each open
    /// directory; a directory not listed yet gets one placeholder whose
    /// appearance asks for it.
    private func lines(root: String, path: String, depth: Int) -> [Line] {
        guard let entries = model.fileEntries(chat: chat, root: root, path: path) else {
            return [Line(node: FileNode(chat: chat, root: root, path: path, name: "", dir: true, placeholder: true), depth: depth)]
        }
        var out: [Line] = []
        for entry in entries {
            let childPath = AppModel.childPath(path, entry.name)
            out.append(Line(node: FileNode(chat: chat, root: root, path: childPath, name: entry.name, dir: entry.dir, size: entry.size), depth: depth))
            if entry.dir, expanded.contains(key(root, childPath)) {
                out += lines(root: root, path: childPath, depth: depth + 1)
            }
        }
        return out
    }

    private func toggle(_ node: FileNode) {
        let k = key(node.root, node.path)
        if expanded.contains(k) { expanded.remove(k) } else { expanded.insert(k) }
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        let node = line.node
        if node.placeholder {
            HStack(spacing: 2) {
                Color.clear.frame(width: Self.indent(depth: line.depth) + FileRow.disclosureWidth, height: 1)
                placeholder(node)
            }
        } else {
            FileRow(
                node: node, subtitle: nil, depth: line.depth,
                expanded: node.dir ? expanded.contains(key(node.root, node.path)) : nil,
                toggle: { toggle(node) })
        }
    }

    @ViewBuilder
    private func placeholder(_ node: FileNode) -> some View {
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
            .hoverHighlight()
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
    /// How deep it sits in the tree (0 in the filter's flat list).
    var depth: Int = 0
    /// Whether a directory in the tree is open: draws the disclosure
    /// arrow. `nil` for a file, and in the flat list.
    var expanded: Bool? = nil
    /// Opens or closes a directory in the tree; `nil` in the flat list.
    var toggle: (() -> Void)? = nil

    /// The column the disclosure arrow sits in, kept for files too so names line up.
    static let disclosureWidth: CGFloat = 14
    @EnvironmentObject private var model: AppModel

    private var absolutePath: String? {
        model.absolutePath(
            chat: node.chat, root: node.root, path: (node.path as NSString).deletingLastPathComponent, name: node.name)
    }

    /// The file the viewer (or the document view) shows right now.
    private var isShown: Bool {
        guard !node.dir, let path = absolutePath else { return false }
        return model.documentMode ? model.documentFile == path : model.current[node.chat]?.location == path
    }

    var body: some View {
        HStack(spacing: 6) {
            if toggle != nil {
                HStack(spacing: 0) {
                    Color.clear.frame(width: FileTree.indent(depth: depth), height: 1)
                    Image(systemName: expanded == true ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .opacity(expanded == nil ? 0 : 1)
                        .frame(width: Self.disclosureWidth)
                }
                .padding(.trailing, -4)
            }
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
        .padding(.vertical, 1)
        .background(isShown ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        // The whole line answers, arrow and indent included.
        .contentShape(Rectangle())
        .hoverHighlight()
        .help(absolutePath ?? node.name)
        .onTapGesture {
            if node.dir { toggle?(); return }
            guard let path = absolutePath else { return }
            model.reveal(file: path, in: node.chat)
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
            Button(model.isBookmarked(path) ? "Remove bookmark" : "Bookmark") { model.toggleBookmark(path) }
            if !node.dir {
                Button("Open in Obsidian") { Obsidian.open(path: path) }
                    .disabled(!Obsidian.isInstalled)
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

// MARK: - The header's icon buttons

/// One of the FILES header's 18-point icon buttons (F1: search, refresh,
/// expand).
struct HeaderIcon: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Bookmarks (F2, v0.4's words)

/// The Files pane's Bookmarks tab: BOOKMARKS (from settings, by absolute
/// path) then CHANGED THIS SESSION (the files the agent created or edited,
/// newest change first, each with the time it last changed; no reads).
struct BookmarksView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let bookmarks = model.settings.pinnedFiles
                SidebarSectionLabel("Bookmarks")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                if bookmarks.isEmpty {
                    hint("Bookmark a file from its menu or the document view.")
                }
                ForEach(bookmarks, id: \.self) { path in
                    BookmarkRow(chat: chat, path: path, time: nil)
                }
                // In single presentation "this session" is the live one,
                // even while an earlier session is open read-only.
                let session = model.isSinglePresentation ? (model.liveSession?.chat ?? chat) : chat
                let changed = model.changedFiles(chat: session)
                SidebarSectionLabel("Changed this session")
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                if changed.isEmpty {
                    hint("Files the agent creates or edits show here.")
                }
                ForEach(changed, id: \.path) { file in
                    BookmarkRow(chat: chat, path: file.path, time: file.time())
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
    }
}

/// One Bookmarks-tab row: icon, name, and for a changed file the time it
/// last changed. A click shows a file where the person is looking (viewer
/// or document view); a bookmarked folder is revealed in Finder.
struct BookmarkRow: View {
    let chat: Int
    let path: String
    /// `9:14` for a changed file; nil for a bookmark.
    let time: String?
    @EnvironmentObject private var model: AppModel

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }
    private var isDirectory: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
    private var isShown: Bool {
        model.documentMode ? model.documentFile == path : model.current[chat]?.location == path
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDirectory ? "folder" : FileIcon.systemName(for: name))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let time, !time.isEmpty {
                Text(time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(isShown ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 8)
        .help(path)
        .onTapGesture {
            if isDirectory {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                model.reveal(file: path, in: chat)
            }
        }
        .contextMenu {
            if !isDirectory {
                Button("Open in viewer") { model.reveal(file: path, in: chat) }
                Button("Add to chat") { model.attach([path], to: chat) }
                Button("Open in Obsidian") { Obsidian.open(path: path) }
                    .disabled(!Obsidian.isInstalled)
                Divider()
            }
            Button(model.isBookmarked(path) ? "Remove bookmark" : "Bookmark") { model.toggleBookmark(path) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        .draggable(URL(fileURLWithPath: path))
    }
}

/// The SF Symbol a file's name gets, by media kind (shared by the tree,
/// Bookmarks, quick open and the document view).
enum FileIcon {
    static func systemName(for name: String) -> String {
        switch Media.of(path: name) {
        case .markdown: "doc.richtext"
        case .image: "photo"
        case .html: "globe"
        case .pdf: "doc.text"
        case .text: "doc.plaintext"
        case .url: "link"
        case .other: URL(fileURLWithPath: name).pathExtension.lowercased() == "csv" ? "tablecells" : "doc"
        }
    }
}


/// The Folder | Bookmarks switch under the FILES header (F1/F2): two halves
/// spanning the sidebar. A segmented `Picker` keeps its own narrow width on
/// macOS, so this is drawn by hand.
struct FilesTabSwitch: View {
    @Binding var selection: AppModel.FilesTab

    var body: some View {
        HStack(spacing: 2) {
            item("Folder", .folder)
            item("Bookmarks", .bookmarks)
        }
        .padding(2)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files view")
    }

    private func item(_ title: String, _ tab: AppModel.FilesTab) -> some View {
        let on = selection == tab
        return Button { selection = tab } label: {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.text : Theme.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(on ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
