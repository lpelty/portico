import SwiftUI

/// The window as the A1 frame lays it out (`design/portico.pen`,
/// "A1 · Classic three-column"): a sidebar of chats and files on the left
/// (260 until dragged), the conversation in the middle under a 52-high
/// toolbar and a 30-high status strip, and the viewer on the right (440
/// for documents, 640 for web pages, until dragged; `ColumnWidths`). The
/// toolbar's two end buttons collapse the side columns; the sidebar's top band is
/// where the traffic lights sit, so the window has no title bar of its own.
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: Settings
    /// The width a column had when its divider drag began.
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let widths = columnWidths(window: geometry.size.width)
            HStack(spacing: 0) {
                if let sidebar = widths.sidebar {
                    SidebarColumn()
                        .frame(width: sidebar)
                        .transition(.move(edge: .leading))
                    ColumnDivider(
                        onDrag: { dx in
                            let start = dragStart ?? sidebar
                            dragStart = start
                            settings.sidebarWidth = ColumnWidths.clampSidebar(start + dx)
                        },
                        onEnd: { dragStart = nil },
                        onReset: { settings.sidebarWidth = ColumnWidths.sidebarDefault })
                }
                MainColumn()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The shown chat's viewer: the conversation's, or (Y1) the
                // live session's beside the welcome that continues it.
                if let chat = model.shownChat, let viewer = widths.viewer {
                    ColumnDivider(
                        onDrag: { dx in
                            // In focus the split is fixed; the widths to come back to stay as they were.
                            guard !focused else { return }
                            let start = dragStart ?? viewer
                            dragStart = start
                            settings.setViewerWidth(
                                ColumnWidths.clampViewer(start - dx, sidebar: widths.sidebar ?? 0, window: geometry.size.width),
                                for: viewerFit)
                        },
                        onEnd: { dragStart = nil },
                        onReset: {
                            guard !focused else { return }
                            settings.setViewerWidth(ColumnWidths.viewerDefault(for: viewerFit), for: viewerFit)
                        })
                    ViewerView(chat: chat)
                        .frame(width: viewer)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Theme.window)
        .askToLogDialog(model)
        .overlay {
            if model.quickOpenShown, let chat = model.filesChat {
                QuickOpenView(chat: chat)
            }
        }
        // No title bar: the columns run to the top edge, and the sidebar's
        // first band is where the traffic lights sit.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeInOut(duration: 0.18), value: model.sidebarShown)
        .animation(.easeInOut(duration: 0.18), value: viewerShown)
        .animation(.easeInOut(duration: 0.18), value: focused)
        // A prototype after a document: the viewer moves to the width
        // remembered for that fit (not while a divider is being dragged).
        .animation(dragStart == nil ? .easeInOut(duration: 0.18) : nil, value: viewerFit)
        .frame(minWidth: Theme.minimumWindowSize.width, minHeight: Theme.minimumWindowSize.height)
    }

    private var viewerShown: Bool {
        guard !model.documentMode else { return false }
        return model.shownChat.map { model.isViewerShown(for: $0) } ?? false
    }

    /// The viewer's fit: the current artifact's, reading when nothing is shown.
    private var viewerFit: ColumnWidths.Fit {
        ColumnWidths.Fit(media: model.shownChat.flatMap { model.current[$0]?.media })
    }

    /// Focus (V3) is on for the chat shown and its viewer is up.
    private var focused: Bool {
        guard let chat = model.shownChat else { return false }
        return model.isFocused(chat: chat) && viewerShown
    }

    /// The remembered widths of the columns that are shown, fitted to the
    /// window; in focus, no sidebar and the viewer's focus width.
    private func columnWidths(window: CGFloat) -> (sidebar: CGFloat?, viewer: CGFloat?) {
        if focused { return (nil, ColumnWidths.focusViewer(window: window)) }
        return ColumnWidths.fit(
            sidebar: model.sidebarShown ? settings.sidebarWidth : nil,
            viewer: viewerShown ? settings.viewerWidth(for: viewerFit) : nil,
            window: window)
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
                // S1: the session card and Earlier, then the files. Earlier
                // is drawn above the files so all of the line between them
                // can be grabbed.
                SessionSidebar()
                    .zIndex(1)
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
        } else {
            // Decided from state before drawing (v0.6): never a welcome
            // that then jumps to a conversation.
            switch model.mainScreen {
            case .conversation(let chat):
                ConversationView(chat: chat)
                    .id(chat)
            case .start, .continuing:
                StartView()
            case .waiting:
                Color.clear
            }
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
                shown: model.sidebarShown, side: .leading,
                help: model.sidebarVisible ? "Hide the sidebar" : "Show the sidebar"
            ) { model.sidebarVisible.toggle() }
            .disabled(model.awaitingFirstSession)
            HStack(spacing: 8) {
                BrandMark(brand: model.brand)
                Text(model.brand.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The brand keeps its room; the title truncates first, and
            // nothing wraps when the main column is narrow (W4).
            .layoutPriority(1)
            if let title = chatTitle {
                Text("/")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                    .fixedSize()
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let chat = model.shownChat, !model.documentMode {
                let shown = model.isViewerShown(for: chat)
                PanelToggle(shown: shown, side: .trailing, help: shown ? "Hide the viewer" : "Show the viewer") {
                    model.setViewer(visible: !shown, for: chat)
                }
            }
        }
        .padding(.leading, model.sidebarShown ? 16 : Theme.trafficLightsInset)
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
        guard let id = model.shownChat else { return model.mainScreen == .waiting ? nil : model.startTitle }
        if model.isSinglePresentation {
            return "Session \(id)"
        }
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
        .buttonStyle(.hover)
        .help(help)
        .accessibilityLabel(help)
    }
}
