import SwiftUI

/// The window: sidebar of chats on the left, the conversation in the
/// centre, the viewer on the right when the chat has artifacts.
/// The status strip under the toolbar says what the chat, the gateway and
/// the socket are doing (spec §5.5).
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            VStack(spacing: 0) {
                StatusStrip()
                Divider()
                detail
            }
        }
        .navigationTitle(model.brand.name)
        .frame(minWidth: 720, minHeight: 480)
    }

    /// The chat list, and under it the Files pane for the selected chat
    /// when the gateway offers files (`hello.capabilities`).
    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            BrandHeader(brand: model.brand)
            if let chat = model.selected, model.hello?.capabilities.contains("files") == true {
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
    }

    /// The conversation, and the viewer beside it when the chat has
    /// produced something and the person has not collapsed it.
    @ViewBuilder
    private var detail: some View {
        if let chat = model.selected {
            HSplitView {
                ConversationView(chat: chat)
                    .id(chat)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                if model.isViewerShown(for: chat) {
                    ViewerView(chat: chat)
                        .frame(minWidth: 280, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                if !(model.artifacts[chat] ?? []).isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.viewerVisible.toggle()
                        } label: {
                            Label("Viewer", systemImage: "sidebar.right")
                        }
                        .help(model.viewerVisible ? "Hide the viewer" : "Show the viewer")
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No chat selected", systemImage: "sidebar.left",
                description: Text("Pick a chat in the sidebar, or start one with New Chat."))
        }
    }
}
