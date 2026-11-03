import AppKit
import SwiftUI

/// What a tool row draws as (v0.18): the app's card when its page came, a
/// thread proposal's card, a question's record, a mark, or the plain row.
enum ToolRowContent: Equatable {
    case app, proposal, question, mark, row

    @MainActor
    static func kind(of row: ToolRow, model: AppModel) -> ToolRowContent {
        if model.proposal(forToolUse: row.toolUseId) != nil { return .proposal }
        if model.app(forToolUse: row.toolUseId) != nil { return .app }
        if QuestionRecord.isRecord(row) { return .question }
        if row.tool == ViewerSteps.markTool { return .mark }
        return .row
    }
}

/// An MCP app's card in place of its tool row (AQ1, AQ2): the header
/// "<server_title> · <tool>" with Reload (when frozen) and Open in viewer,
/// then the page, sized by its `size-changed` up to 520 pt. A frozen card
/// shows its last look, or after a restart "<server_title> · Reload to
/// show it again". The border is drawn only when the resource prefers it.
struct AppCard: View {
    let state: AppState
    let chat: Int
    @EnvironmentObject private var model: AppModel

    static let radius: CGFloat = 12

    var body: some View {
        let image = model.appSnapshot(state.toolUseId)
        let shown = AppCardPresentation(state: state, hasImage: image != nil)
        VStack(spacing: 0) {
            header(shown)
            Rectangle().fill(Theme.border).frame(height: 1)
            page(shown, image: image)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            if state.prefersBorder {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous).stroke(Theme.border, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shown.accessibilityLabel)
    }

    private func header(_ shown: AppCardPresentation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .font(Theme.iconFont(13))
                .foregroundStyle(Theme.text2)
                .accessibilityHidden(true)
            Text(shown.title)
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(shown.subtitle)
                .scaledFont(12)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.frozen {
                AppHeaderButton(title: AppCardPresentation.reload, symbol: "arrow.clockwise") {
                    model.reloadApp(state.toolUseId, chat: chat)
                }
                .disabled(state.reloading != nil || model.connection != .connected)
            }
            AppHeaderButton(title: AppCardPresentation.openInViewer, symbol: "sidebar.right") {
                model.openAppInViewer(state.toolUseId, chat: chat)
            }
            .disabled(state.html == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func page(_ shown: AppCardPresentation, image: NSImage?) -> some View {
        if !state.frozen || model.appPages[AppPageKey(toolUseId: state.toolUseId, placement: .card)] != nil && image == nil {
            // Live, or freezing (its page still drawn until its image is taken).
            MCPAppView(toolUseId: state.toolUseId, placement: .card, model: model)
                .frame(height: state.height)
                .id(state.generation)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(0.55)
                .accessibilityLabel("The app's last look")
        } else {
            Text(shown.placeholder ?? "")
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }
}

/// The card header's buttons (AQ1/AQ2): control fill, hairline border, 6 pt corners.
struct AppHeaderButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(Theme.iconFont(11))
                    .foregroundStyle(Theme.text2)
                    .accessibilityHidden(true)
                Text(title)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The viewer's copy of an app's page (ruling 36): the header
/// "<server_title> · <tool>" with only X, and a fresh page at full size.
struct AppViewerPane: View {
    let chat: Int
    let state: AppState
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .font(Theme.iconFont(13))
                    .foregroundStyle(Theme.text2)
                    .accessibilityHidden(true)
                Text("\(state.serverTitle) · \(state.tool)")
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                ViewerCloseButton(help: "Close the app", label: "Close the app") {
                    model.closeAppViewer(chat: chat)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: Theme.toolbarHeight)
            Rectangle().fill(Theme.border).frame(height: 1)
            MCPAppView(toolUseId: state.toolUseId, placement: .viewer, model: model)
                .id(state.generation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.serverTitle) app, \(state.tool)")
    }
}
