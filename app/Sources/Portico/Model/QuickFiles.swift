import AppKit
import Foundation

// MARK: - Files, v0.2 (F1–F4)

/// A file the session's tools touched, read or written (quick open
/// ranks these after the bookmarks).
struct TouchedFile: Equatable, Sendable {
    var path: String
    /// A write-like tool touched it (Write, Edit, NotebookEdit…); else it was read.
    var wrote: Bool

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A file the agent created or edited this session (v0.4's "Changed this
/// session"), with when it last changed.
struct ChangedFile: Equatable, Sendable {
    var path: String
    /// The last change's time, from its tool events; nil when unknown.
    var at: Date?

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// `9:14`, the app's clock; empty when the time is unknown.
    func time(calendar: Calendar = .current) -> String {
        at.map { SessionTime.clock($0, calendar: calendar) } ?? ""
    }
}

/// One row of quick open (F4): a file by absolute path, where it lives,
/// and whether it is pinned or was touched this session.
struct QuickOpenItem: Equatable, Identifiable, Sendable {
    var path: String
    var name: String
    /// `Research vault / Reports`.
    var location: String
    var pinned: Bool
    var touched: Bool

    var id: String { path }
}

/// One `files.search` hit, resolved to an absolute path.
struct SearchHit: Equatable, Identifiable, Sendable {
    var root: String
    /// Relative to the root, as the gateway sent it.
    var path: String
    var absolutePath: String
    var snippet: String?

    var id: String { absolutePath }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// The document view's text search: one `files.search` per root, hits
/// gathered as each answers.
struct FileSearch: Equatable, Sendable {
    var query: String
    var hits: [SearchHit] = []
    /// Request id → root, for the searches not answered yet.
    var pending: [String: String] = [:]

    var isSearching: Bool { !pending.isEmpty }
}

extension AppModel {
    /// Tool names that write the file they name; anything else reads it.
    static let writeTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    static func isWriteTool(_ tool: String) -> Bool {
        if writeTools.contains(tool) { return true }
        let lower = tool.lowercased()
        return lower.contains("write") || lower.contains("edit")
    }

    /// The file a tool call names: `file_path` or `notebook_path` in its
    /// input, else its summary when that is an absolute path to a file.
    /// Relative paths are resolved against the chat's folder.
    static func filePath(of row: ToolRow, folder: String?) -> String? {
        for key in ["file_path", "notebook_path"] {
            if let value = row.input[key]?.stringValue, !value.isEmpty {
                return resolve(value, folder: folder)
            }
        }
        let summary = row.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.hasPrefix("/") && !summary.contains("\n") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: summary, isDirectory: &isDir), !isDir.boolValue {
                return summary
            }
        }
        return nil
    }

    private static func resolve(_ path: String, folder: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || folder == nil { return URL(fileURLWithPath: expanded).standardized.path }
        return URL(fileURLWithPath: folder!).appendingPathComponent(expanded).standardized.path
    }

    /// The files this chat's tool calls touched, newest first, one row per
    /// path; `wrote` when any call wrote it.
    func touchedFiles(chat: Int) -> [TouchedFile] {
        let folder = summary(of: chat)?.folder
        var order: [String] = []
        var wrote: [String: Bool] = [:]
        for item in (transcripts[chat] ?? []).reversed() {
            guard case .tool(let row) = item, let path = Self.filePath(of: row, folder: folder) else { continue }
            if wrote[path] == nil { order.append(path) }
            wrote[path] = (wrote[path] ?? false) || Self.isWriteTool(row.tool)
        }
        return order.map { TouchedFile(path: $0, wrote: wrote[$0] ?? false) }
    }

    /// The files this chat's tools created or edited (no reads, no failed
    /// writes), newest change first, one row per path with the time of its
    /// last change.
    func changedFiles(chat: Int) -> [ChangedFile] {
        let folder = summary(of: chat)?.folder
        var seen = Set<String>()
        var files: [ChangedFile] = []
        for item in (transcripts[chat] ?? []).reversed() {
            guard case .tool(let row) = item, Self.isWriteTool(row.tool), row.ok != false,
                let path = Self.filePath(of: row, folder: folder), seen.insert(path).inserted
            else { continue }
            files.append(ChangedFile(path: path, at: SessionTime.parse(row.at)))
        }
        return files
    }

    // MARK: bookmarks

    /// Bookmarked, by absolute path. Stored as `pinnedFiles` (v0.2's word)
    /// so bookmarks made before v0.4 survive.
    func isBookmarked(_ path: String) -> Bool {
        settings.pinnedFiles.contains(path)
    }

    /// Bookmark a file (or folder), or remove its bookmark; kept in settings.
    func toggleBookmark(_ path: String) {
        objectWillChange.send()
        if let index = settings.pinnedFiles.firstIndex(of: path) {
            settings.pinnedFiles.remove(at: index)
        } else {
            settings.pinnedFiles.append(path)
        }
    }

    // MARK: where a file lives

    /// `Research vault / Reports` for a path under one of the chat's roots
    /// (the chat's own root reads as its folder's name), else the parent
    /// folder with `~` for home.
    func location(of path: String, chat: Int) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        for root in browsableRoots(for: chat) {
            let base = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
            guard parent == base || parent.hasPrefix(base + "/") else { continue }
            let label = root.name == Self.chatRoot ? URL(fileURLWithPath: base).lastPathComponent : root.name
            let rest = parent.dropFirst(base.count).split(separator: "/").map(String.init)
            return ([label] + rest).joined(separator: " / ")
        }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    // MARK: quick open (F4)

    /// Every file the chat's listings hold, as absolute paths.
    func listedFiles(chat: Int) -> [String] {
        var paths: [String] = []
        for (key, entries) in fileTree where key.chat == chat {
            for entry in entries where !entry.dir {
                if let path = absolutePath(chat: chat, root: key.root, path: key.path, name: entry.name) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    static let quickOpenLimit = 50

    /// Quick open's rows for `query`: file names containing it (all files
    /// when empty), bookmarked first, then touched this session, then names
    /// that start with the query, then shorter names; at most 50.
    func quickOpenItems(chat: Int, query: String) -> [QuickOpenItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let touched = Set(touchedFiles(chat: chat).map(\.path))
        let pinned = settings.pinnedFiles.filter { !Self.isDirectoryPath($0) }
        var seen = Set<String>()
        var items: [QuickOpenItem] = []
        for path in pinned + touchedFiles(chat: chat).map(\.path) + listedFiles(chat: chat) {
            guard seen.insert(path).inserted else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard needle.isEmpty || name.lowercased().contains(needle) else { continue }
            items.append(QuickOpenItem(
                path: path, name: name, location: location(of: path, chat: chat),
                pinned: pinned.contains(path), touched: touched.contains(path)))
        }
        func rank(_ item: QuickOpenItem) -> (Int, Int, Int, String) {
            let group = item.pinned ? 0 : item.touched ? 1 : 2
            let prefix = !needle.isEmpty && item.name.lowercased().hasPrefix(needle) ? 0 : 1
            return (group, prefix, item.name.count, item.name.lowercased())
        }
        return Array(items.sorted { rank($0) < rank($1) }.prefix(Self.quickOpenLimit))
    }

    /// How deep quick open lists folders on its own, and how many
    /// listings may be out at once: bounded so a big root costs little.
    static let prefetchDepth = 3
    static let prefetchInFlight = 16

    /// Ask for the chat's folders down to `prefetchDepth`, a few at a time,
    /// skipping hidden folders and `node_modules`. Called when quick open
    /// shows and again as listings arrive.
    func prefetchFiles(chat: Int) {
        for root in browsableRoots(for: chat) {
            prefetch(chat: chat, root: root.name, path: "", level: 0)
        }
    }

    private func prefetch(chat: Int, root: String, path: String, level: Int) {
        guard pendingFileLists.count < Self.prefetchInFlight else { return }
        guard let entries = fileEntries(chat: chat, root: root, path: path) else {
            if fileListError(chat: chat, root: root, path: path) == nil {
                listFiles(chat: chat, root: root, path: path)
            }
            return
        }
        guard level < Self.prefetchDepth else { return }
        for entry in entries where entry.dir && !entry.name.hasPrefix(".") && entry.name != "node_modules" {
            prefetch(chat: chat, root: root, path: Self.childPath(path, entry.name), level: level + 1)
        }
    }

    private static func isDirectoryPath(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: the document view (F3)

    /// Open the document view, on `file` when given. The sidebar's files
    /// switch to Bookmarks while it is open.
    func openDocumentView(file: String? = nil) {
        if !documentMode {
            filesTabBeforeDocument = filesTab
            filesTab = .bookmarks
            documentMode = true
        }
        if let file { documentFile = file }
    }

    /// Back to the conversation; the files tab goes back to what it was.
    func closeDocumentView() {
        guard documentMode else { return }
        documentMode = false
        filesTab = filesTabBeforeDocument ?? .folder
        filesTabBeforeDocument = nil
        fileSearch = nil
    }

    func toggleDocumentView() {
        documentMode ? closeDocumentView() : openDocumentView()
    }

    /// Show a file where the person is looking: the document view when it
    /// is open, else the viewer column (quick open's Return).
    func reveal(file path: String, in chat: Int) {
        if documentMode {
            documentFile = path
        } else {
            openArtifact(file: path, in: chat)
        }
    }

    // MARK: text search (files.search)

    /// Search names and text under every root of the chat: one
    /// `files.search` per root; an empty query clears the search (the
    /// document view shows the tree). Needs the `files.search` capability.
    func searchFiles(chat: Int, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, offers("files.search") else {
            fileSearch = nil
            return
        }
        var search = FileSearch(query: trimmed)
        var frames: [ClientMessage] = []
        for root in browsableRoots(for: chat) {
            let id = Self.requestId()
            search.pending[id] = root.name
            frames.append(.filesSearch(FilesSearch(root: root.name, query: trimmed, chat: chat, id: id)))
        }
        fileSearch = search
        frames.forEach(send)
    }

    /// A `files.results` for a search still showing lands its hits; one
    /// for a search since replaced goes nowhere.
    func applySearchResults(_ results: FilesResults) {
        guard let id = results.id, var search = fileSearch, search.pending[id] != nil else { return }
        search.pending[id] = nil
        let chat = selected ?? results.chat
        for hit in results.hits ?? [] {
            let absolute: String
            if let chat, let base = rootPath(root: results.root, chat: chat) {
                absolute = URL(fileURLWithPath: base).appendingPathComponent(hit.path).path
            } else {
                absolute = hit.path
            }
            guard !search.hits.contains(where: { $0.absolutePath == absolute }) else { continue }
            search.hits.append(SearchHit(root: results.root, path: hit.path, absolutePath: absolute, snippet: hit.snippet))
        }
        fileSearch = search
    }
}

// MARK: - Obsidian

/// "Open in Obsidian": `obsidian://open?path=<absolute path>`; Obsidian
/// finds the vault that holds the file itself (design §2.6).
enum Obsidian {
    /// Unreserved characters only: every `/`, space and `&` is encoded.
    static func url(path: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "obsidian://open?path=\(encoded)")
    }

    /// Whether anything handles `obsidian://` on this Mac.
    @MainActor static var isInstalled: Bool {
        guard let probe = URL(string: "obsidian://open") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    @MainActor static func open(path: String) {
        guard let url = url(path: path) else { return }
        NSWorkspace.shared.open(url)
    }

    static let notInstalledHelp = "Obsidian is not installed"
}
