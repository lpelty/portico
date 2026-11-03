import SwiftUI

/// How the Mark row reads (v0.14 3.5): "Mark · trail-detail.html · 3 areas",
/// and whether "Show again" is offered. View-free so it can be tested.
struct MarkRowPresentation: Equatable {
    let row: ToolRow
    /// The stored call, if the app drew this one (a resumed session has none).
    let call: MarkCall?

    var showsShowAgain: Bool { call != nil && !isFailed }

    /// Running and failed read as on any tool row (`ToolRowPresentation`).
    private var tool: ToolRowPresentation { ToolRowPresentation(row: row) }
    var isRunning: Bool { !row.finished }
    var isFailed: Bool { row.finished && row.ok == false }
    /// `running`, the finish summary, or `failed: <why>` (the row's help).
    var stateText: String { tool.stateText }
    /// Why it failed, on the row in the failure colour; `nil` unless it
    /// failed with words.
    var failureDetail: String? { tool.failureDetail }

    private static func areas(_ n: Int) -> String { n == 1 ? "1 area" : "\(n) areas" }

    var text: String {
        // A failed call drew nothing: no area count to suggest it did.
        if isFailed { return "Mark" }
        if let call, let first = call.marks.first {
            return "Mark \u{B7} \(first.page.name) \u{B7} \(Self.areas(call.marks.count))"
        }
        if case .array(let list)? = row.input["marks"], !list.isEmpty {
            return "Mark \u{B7} \(Self.areas(list.count))"
        }
        return "Mark"
    }
}

/// The Mark row: the ordinary tool-row look with the `scope` icon, and an
/// accent "Show again" when the app holds the call.
struct MarkRowView: View {
    let row: ToolRow
    var chat: Int? = nil
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Observe the store so "Show again" appears once the call is recorded.
        MarkRowBody(row: row, chat: chat, store: model.markStore, agent: model.viewerAgent)
    }
}

private struct MarkRowBody: View {
    let row: ToolRow
    let chat: Int?
    @ObservedObject var store: MarkStore
    let agent: ViewerAgent
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        let call = chat.flatMap { store.call(chat: $0, toolUseId: row.toolUseId) }
        let shown = MarkRowPresentation(row: row, call: call)
        HStack(spacing: 8) {
            Group {
                if shown.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else if shown.isFailed {
                    Image(systemName: "xmark")
                        .font(Theme.iconFont(11, weight: .semibold))
                        .foregroundStyle(Theme.deny)
                } else {
                    Image(systemName: "scope")
                        .font(Theme.iconFont(11, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                }
            }
            .frame(width: 14, height: 14)
            Text(shown.text)
                .scaledFont(13, weight: .medium)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            if let failure = shown.failureDetail {
                Text(failure)
                    .scaledFont(12)
                    .foregroundStyle(Theme.deny)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if shown.showsShowAgain, let chat {
                Button {
                    agent.showAgain(toolUseId: row.toolUseId, chat: chat)
                } label: {
                    HStack(spacing: 4) {
                        Text("Show again").scaledFont(12, weight: .medium)
                        Image(systemName: "chevron.right").font(Theme.iconFont(10, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(model.brand.accent ?? Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(hovering ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .tip(shown.stateText)
        .accessibilityElement(children: .contain)
    }
}
