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
                if let viewer = widths.viewer {
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
                    ViewerColumn(chat: model.shownChat)
                        .frame(width: viewer)
                        // v0.11 (67): the panel eases in, fading as it slides,
                        // rather than appearing all at once.
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.window)
        .askToLogDialog(model)
        .gatewayConfirmDialog(model, place: .window)
        .overlay {
            if model.quickOpenShown, let chat = model.filesChat {
                QuickOpenView(chat: chat)
            }
        }
        // No title bar: the columns run to the top edge, and the sidebar's
        // first band is where the traffic lights sit.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeInOut(duration: 0.18), value: model.sidebarShown)
        .animation(.easeOut(duration: 0.22), value: viewerShown)
        .animation(.easeInOut(duration: 0.18), value: focused)
        // A prototype after a document: the viewer moves to the width
        // remembered for that fit (not while a divider is being dragged).
        .animation(dragStart == nil ? .easeInOut(duration: 0.18) : nil, value: viewerFit)
        .frame(minWidth: Theme.minimumWindowSize.width, minHeight: Theme.minimumWindowSize.height)
    }

    private var viewerShown: Bool {
        model.viewerColumnShown
    }

    /// The viewer's fit: a space's (700 where the window allows), else the
    /// current artifact's, reading when nothing is shown.
    private var viewerFit: ColumnWidths.Fit {
        if model.openSpace != nil { return .space }
        return ColumnWidths.Fit(media: model.shownChat.flatMap { model.current[$0]?.media })
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
            // Pinned below whatever scrolls above it (v0.9 decision 6, AE1).
            SidebarFooter()
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
/// (icon and name), the spaces switcher (when there are spaces), and
/// collapse the viewer. The chat's title is not here: the session card
/// names the session. The whole bar drags the window, since there is no
/// title bar.
struct MainToolbar: View {
    @EnvironmentObject private var model: AppModel

    private var items: [ToolbarLayout.Item] {
        ToolbarLayout.items(
            showSwitcher: ToolbarLayout.showsSwitcher,
            showViewerToggle: model.shownChat != nil && !model.documentMode)
    }

    var body: some View {
        let items = items
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                view(for: item)
                    .padding(.trailing, ToolbarLayout.gap(after: item, next: items.indices.contains(index + 1) ? items[index + 1] : nil))
            }
        }
        .padding(.leading, model.sidebarShown ? 16 : Theme.trafficLightsInset)
        .padding(.trailing, 16)
        .frame(height: Theme.toolbarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    @ViewBuilder
    private func view(for item: ToolbarLayout.Item) -> some View {
        switch item {
        case .sidebarToggle:
            PanelToggle(
                shown: model.sidebarShown, side: .leading,
                help: model.sidebarVisible ? "Hide the sidebar" : "Show the sidebar"
            ) { model.sidebarVisible.toggle() }
            .disabled(model.awaitingFirstSession)
        case .brand:
            HStack(spacing: 8) {
                if let header = model.brand.headerImage {
                    HeaderImage(image: header, label: model.brand.name)
                } else {
                    BrandMark(brand: model.brand)
                    Text(model.brand.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .switcher:
            // The brand's name truncates first when the column is narrow.
            SpaceSwitcher().layoutPriority(1)
        case .spacer:
            Spacer(minLength: 0)
        case .viewerToggle:
            if let chat = model.shownChat {
                let shown = model.isViewerShown(for: chat)
                PanelToggle(shown: shown, side: .trailing, help: shown ? "Hide the viewer" : "Show the viewer") {
                    model.setViewer(visible: !shown, for: chat)
                }
            }
        }
    }
}

/// The brand's icon from `hello` (rounded when it is a flat square, v0.7
/// decision 5), or a 20-point rounded square in the accent when the
/// gateway sent none (the frame's placeholder).
struct BrandMark: View {
    let brand: BrandPresentation

    var body: some View {
        if let icon = brand.icon {
            BrandIcon(icon: icon, side: 20)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(brand.accent ?? Theme.accent)
                .frame(width: 20, height: 20)
        }
    }
}

/// The deployment's header image in place of the mark and the name (v0.7,
/// frame "AB1 · Header image sizes"): 28 points tall, as wide as its own
/// proportions make it, never stretched; a very wide image is capped at
/// `maxWidth` and drawn shorter instead.
struct HeaderImage: View {
    let image: NSImage
    let label: String

    static let height: CGFloat = 28
    static let maxWidth: CGFloat = 200

    /// The drawn size: `height` tall at the image's aspect ratio, or
    /// `maxWidth` wide when that would be wider.
    static func size(of image: NSImage) -> CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: height, height: height) }
        let ratio = natural.width / natural.height
        let width = height * ratio
        return width <= maxWidth ? CGSize(width: width, height: height) : CGSize(width: maxWidth, height: maxWidth / ratio)
    }

    var body: some View {
        let size = Self.size(of: image)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .accessibilityLabel(label)
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
