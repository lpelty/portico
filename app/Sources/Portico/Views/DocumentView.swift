import AppKit
import SwiftUI

/// The document view, frame "F3 · Document view" (⌘⇧F, or the FILES
/// header's expand icon). It replaces the conversation and the viewer: a
/// search field across the top (text search through `files.search` when
/// the gateway offers it, file names otherwise; empty shows the tree), the
/// folder tree on the left, the open document on the right with its
/// header (name, where, pin, Open in Obsidian), and the composer aimed at
/// that document. "Conversation" goes back.
struct DocumentView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                Group {
                    if searching { results } else { FileTree(chat: chat) }
                }
                .frame(width: Theme.documentTreeWidth)
                Rectangle().fill(Theme.border).frame(width: 1)
                document
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.window)
        // Typing pauses briefly before a search goes out.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.searchFiles(chat: chat, query: query)
        }
        .onAppear { searchFocused = model.documentFile == nil }
    }

    // MARK: the top bar

    private var rootLabel: String {
        guard let root = model.fileRoots(for: chat).first(where: { $0.name != AppModel.chatRoot }) ?? model.fileRoots(for: chat).first else {
            return "the folders"
        }
        return root.name == AppModel.chatRoot ? URL(fileURLWithPath: root.path).lastPathComponent : root.name
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.text3)
                TextField(
                    model.offers("files.search") ? "Search names and text in \(rootLabel)" : "Find files by name in \(rootLabel)",
                    text: $query
                )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    if query.isEmpty { model.closeDocumentView() } else { query = "" }
                    return .handled
                }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.hover)
                        .foregroundStyle(Theme.text3)
                        .help("Clear the search")
                }
                Text("⌘⇧F")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
            Button {
                model.closeDocumentView()
            } label: {
                Label("Conversation", systemImage: "bubble.left")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .help("Back to the conversation (⌘⇧F)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: search results

    @ViewBuilder
    private var results: some View {
        if model.offers("files.search") {
            let search = model.fileSearch
            List {
                ForEach(search?.hits ?? []) { hit in
                    resultRow(name: hit.name, location: model.location(of: hit.absolutePath, chat: chat), snippet: hit.snippet, path: hit.absolutePath)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if search?.isSearching == true && (search?.hits.isEmpty ?? true) {
                    ProgressView().controlSize(.small)
                } else if search != nil && (search?.hits.isEmpty ?? true) {
                    ContentUnavailableView.search(text: query)
                }
            }
        } else {
            // A gateway without text search: names from what is listed.
            let items = model.quickOpenItems(chat: chat, query: query)
            List(items) { item in
                resultRow(name: item.name, location: item.location, snippet: nil, path: item.path)
            }
            .listStyle(.sidebar)
            .overlay {
                if items.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .onAppear { model.prefetchFiles(chat: chat) }
        }
    }

    private func resultRow(name: String, location: String, snippet: String?, path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: FileIcon.systemName(for: name))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 16)
                Text(name)
                    .font(.system(size: 13, weight: model.documentFile == path ? .semibold : .regular))
                    .lineLimit(1)
            }
            Text(location)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.head)
            if let snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .hoverHighlight()
        .help(path)
        .onTapGesture { model.reveal(file: path, in: chat) }
    }

    // MARK: the document

    @ViewBuilder
    private var document: some View {
        if let path = model.documentFile {
            VStack(spacing: 0) {
                DocumentHeader(path: path, chat: chat)
                Rectangle().fill(Theme.border).frame(height: 1)
                ArtifactContent(artifact: Self.artifact(for: path))
                    .id(path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isSinglePresentation && model.isEnded(chat: chat) {
                    EndedSessionBar(chat: chat)
                        .padding(20)
                } else {
                    InputBar(chat: chat, about: path)
                        .id("\(chat)|\(path)")
                        .padding(20)
                }
            }
        } else {
            ContentUnavailableView(
                "No document open", systemImage: "doc.text",
                description: Text("Pick a file in the tree, or search above."))
        }
    }

    /// The document as the viewer's local artifact, so it renders the
    /// same way (markdown, image, PDF, text…).
    static func artifact(for path: String) -> Artifact {
        Artifact(
            id: AppModel.localArtifactPrefix + path, kind: .file, location: path, media: Media.of(path: path),
            title: URL(fileURLWithPath: path).lastPathComponent, source: .text, open: false)
    }
}

/// The document's header (F3): icon, name, where it lives, a pin toggle
/// and Open in Obsidian (disabled with a tooltip when nothing handles
/// `obsidian://`).
struct DocumentHeader: View {
    let path: String
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let bookmarked = model.isBookmarked(path)
        let obsidian = Obsidian.isInstalled
        HStack(spacing: 10) {
            Image(systemName: FileIcon.systemName(for: path))
                .font(.system(size: 15))
                .foregroundStyle(Theme.text2)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(model.location(of: path, chat: chat))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(path)
            Spacer(minLength: 8)
            Button {
                model.toggleBookmark(path)
            } label: {
                Image(systemName: bookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12))
                    .foregroundStyle(bookmarked ? (model.brand.accent ?? Theme.accent) : Theme.text2)
                    .frame(width: 28, height: 26)
                    .background(bookmarked ? Theme.accentSoft : Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help(bookmarked ? "Remove bookmark" : "Bookmark")
            Button {
                Obsidian.open(path: path)
            } label: {
                Label("Open in Obsidian", systemImage: "arrow.up.right")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .disabled(!obsidian)
            .help(obsidian ? "Open this note in Obsidian" : Obsidian.notInstalledHelp)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }
}
