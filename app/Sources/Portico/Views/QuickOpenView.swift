import SwiftUI

/// Quick open, frame "F4 · Quick open" (⌘P, or the FILES header's search
/// icon): a palette over the window that filters file names from the
/// listings the app holds (listing more, a bounded few at a time), pinned
/// and touched first. ↑/↓ move, Return opens in the viewer (or the
/// document view when it is open), ⌘Return opens in Obsidian, Esc closes.
struct QuickOpenView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var items: [QuickOpenItem] { model.quickOpenItems(chat: chat, query: query) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }
            panel
                .frame(width: Theme.quickOpenWidth)
                .padding(.top, 96)
        }
        .onAppear {
            focused = true
            model.prefetchFiles(chat: chat)
        }
        // As listings arrive, list the next few folders down.
        .onChange(of: model.fileTree.count) { _, _ in model.prefetchFiles(chat: chat) }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text2)
                TextField("Find a file by name", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        openSelected(inObsidian: press.modifiers.contains(.command))
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Rectangle().fill(Theme.border).frame(height: 1)
            results
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }

    @ViewBuilder
    private var results: some View {
        let items = self.items
        if items.isEmpty {
            Text(query.isEmpty ? "Listing files…" : "No file named “\(query)” in what has been listed")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                            row(item, selected: offset == index)
                                .contentShape(Rectangle())
                                .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .id(item.id)
                                .onTapGesture {
                                    index = offset
                                    openSelected(inObsidian: false)
                                }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
                .onChange(of: index) { _, new in
                    if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                }
            }
        }
    }

    private func row(_ item: QuickOpenItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: FileIcon.systemName(for: item.name))
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .frame(width: 16)
            Text(item.name)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(item.location)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if item.pinned {
                Label("bookmarked", systemImage: "bookmark")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            } else if item.touched {
                Text("this session")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .help(item.path)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            hint("↵", "open in viewer")
            hint("⌘↵", "open in Obsidian")
            if model.offers("files.search") {
                hint("⌘⇧F", "search text")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Theme.border, lineWidth: 1))
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundStyle(Theme.text2)
    }

    private func move(_ step: Int) {
        let count = items.count
        guard count > 0 else { return }
        index = min(max(index + step, 0), count - 1)
    }

    private func openSelected(inObsidian: Bool) {
        let items = self.items
        guard items.indices.contains(index) else { return }
        let path = items[index].path
        if inObsidian {
            Obsidian.open(path: path)
        } else {
            model.reveal(file: path, in: chat)
        }
        close()
    }

    private func close() {
        model.quickOpenShown = false
    }
}
