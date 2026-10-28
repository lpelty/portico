import SwiftUI

/// The window as the A1 frame lays it out (`design/portico.pen`,
/// "A1 · Classic three-column"): a 260-wide sidebar of chats and files on
/// the left, the conversation in the middle under a 52-high toolbar and a
/// 30-high status strip, and a 440-wide viewer on the right. The toolbar's
/// two end buttons collapse the side columns; the sidebar's top band is
/// where the traffic lights sit, so the window has no title bar of its own.
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarColumn()
                    .frame(width: Theme.sidebarWidth)
                    .transition(.move(edge: .leading))
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            MainColumn()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let chat = model.selected, model.isViewerShown(for: chat), !model.documentMode {
                Rectangle().fill(Theme.border).frame(width: 1)
                ViewerView(chat: chat)
                    .frame(width: Theme.viewerWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.window)
        .overlay {
            if model.quickOpenShown, let chat = model.filesChat {
                QuickOpenView(chat: chat)
            }
        }
        // No title bar: the columns run to the top edge, and the sidebar's
        // first band is where the traffic lights sit.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeInOut(duration: 0.18), value: model.sidebarVisible)
        .animation(.easeInOut(duration: 0.18), value: viewerShown)
        .frame(minWidth: Theme.minimumWindowSize.width, minHeight: Theme.minimumWindowSize.height)
    }

    private var viewerShown: Bool {
        guard !model.documentMode else { return false }
        return model.selected.map { model.isViewerShown(for: $0) } ?? false
    }
}

extension AppModel {
    /// The chat whose files the sidebar, quick open and the document view
    /// use: the one shown, else (single presentation) the live session.
    var filesChat: Int? {
        guard hello?.capabilities.contains("files") == true else { return nil }
        return selected ?? liveSession?.chat
    }
}

/// The left column: a band for the traffic lights, then the chat list and
/// (when the gateway offers files) the files pane for the selected chat.
struct SidebarColumn: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Theme.toolbarHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            if model.isSinglePresentation {
                // S1: the session card and Earlier, then the files.
                SessionSidebar()
                if let chat = model.filesChat {
                    FilesView(chat: chat)
                        .id(chat)
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            } else if let chat = model.selected, model.hello?.capabilities.contains("files") == true {
                VSplitView {
                    ChatListView()
                        .frame(minHeight: 120)
                    FilesView(chat: chat)
                        .id(chat)
                        .frame(minHeight: 120)
                }
            } else {
                ChatListView()
            }
        }
        .background(Theme.sidebar)
    }
}

/// The middle column: the toolbar, the status strip, the conversation.
struct MainColumn: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            MainToolbar()
            Rectangle().fill(Theme.border).frame(height: 1)
            StatusStrip()
            Rectangle().fill(Theme.border).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
    }

    @ViewBuilder
    private var content: some View {
        if model.documentMode, let chat = model.filesChat {
            DocumentView(chat: chat)
        } else if let chat = model.selected {
            ConversationView(chat: chat)
                .id(chat)
        } else {
            StartView()
        }
    }
}

/// The 52-high bar over the conversation: collapse the sidebar, the brand
/// (icon and name), a slash, the chat's title, and collapse the viewer.
/// The whole bar drags the window, since there is no title bar.
struct MainToolbar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            PanelToggle(
                shown: model.sidebarVisible, side: .leading,
                help: model.sidebarVisible ? "Hide the sidebar" : "Show the sidebar"
            ) { model.sidebarVisible.toggle() }
            HStack(spacing: 8) {
                BrandMark(brand: model.brand)
                Text(model.brand.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            if let title = chatTitle {
                Text("/")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let chat = model.selected, !model.documentMode {
                let shown = model.isViewerShown(for: chat)
                PanelToggle(shown: shown, side: .trailing, help: shown ? "Hide the viewer" : "Show the viewer") {
                    model.setViewer(visible: !shown, for: chat)
                }
            }
        }
        .padding(.leading, model.sidebarVisible ? 16 : Theme.trafficLightsInset)
        .padding(.trailing, 16)
        .frame(height: Theme.toolbarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    /// `Chat #3`, or the alias when the chat has one; `Session 14` in
    /// single presentation; `Files · Research vault` in the document view.
    private var chatTitle: String? {
        if model.documentMode, let chat = model.filesChat {
            let roots = model.fileRoots(for: chat)
            let root = roots.first { $0.name != AppModel.chatRoot } ?? roots.first
            guard let root else { return "Files" }
            return "Files · " + (root.name == AppModel.chatRoot ? URL(fileURLWithPath: root.path).lastPathComponent : root.name)
        }
        if model.isSinglePresentation {
            guard let id = model.selected else { return "New session" }
            return "Session \(id)"
        }
        guard let id = model.selected else { return "New chat" }
        let summary = model.chats.first { $0.chat == id }
        if let alias = summary?.alias, !alias.isEmpty { return alias }
        return "Chat #\(id)"
    }
}

/// The brand's icon from `hello`, or a 20-point rounded square in the
/// accent when the gateway sent none (the frame's placeholder).
struct BrandMark: View {
    let brand: BrandPresentation

    var body: some View {
        if let icon = brand.iconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(brand.accent ?? Theme.accent)
                .frame(width: 20, height: 20)
        }
    }
}

/// One of the toolbar's two end buttons: `sidebar.left` or `sidebar.right`.
struct PanelToggle: View {
    enum Side { case leading, trailing }

    let shown: Bool
    let side: Side
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: side == .leading ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(shown ? Theme.text2 : Theme.text)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
