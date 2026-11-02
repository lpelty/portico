import SwiftUI

/// What the conversation draws, item by item, with runs of viewer steps
/// folded into one entry (v0.13 decision 8, Pen AL5).
enum TranscriptEntry: Identifiable, Equatable {
    case item(TranscriptItem)
    /// Two or more viewer steps in a row; the id is the first step's, so it
    /// stays the same while the run grows.
    case viewerSteps([ToolRow])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .viewerSteps(let rows): "viewer-steps:\(rows.first?.toolUseId ?? "")"
        }
    }

    /// A tool row, or a run of them: what closes up against its neighbours (decision 1).
    var isToolRow: Bool {
        switch self {
        case .item(let item): if case .tool = item { return true }; return false
        case .viewerSteps: return true
        }
    }

    /// `items` with each run of two or more viewer steps folded.
    static func entries(_ items: [TranscriptItem]) -> [TranscriptEntry] {
        var out: [TranscriptEntry] = []
        var run: [ToolRow] = []
        func flush() {
            if run.count >= 2 {
                out.append(.viewerSteps(run))
            } else {
                out += run.map { .item(.tool($0)) }
            }
            run = []
        }
        for item in items {
            if case .tool(let row) = item, ViewerSteps.isStep(row) {
                run.append(row)
            } else {
                flush()
                out.append(.item(item))
            }
        }
        flush()
        return out
    }
}

/// The viewer's steps as the folded row reads them. These are Portico's
/// own tools (the reference gateway's `portico` server, protocol
/// "Viewer"), not an agent's, so the app may know their names.
enum ViewerSteps {
    static let prefix = "mcp__portico__viewer_"

    /// The Mark row stands alone, as "Show in viewer" does (v0.14 3.5).
    static let markTool = "mcp__portico__viewer_mark"

    static func isStep(_ row: ToolRow) -> Bool { row.tool.hasPrefix(prefix) && row.tool != markTool }

    /// `viewer_click` reads "Click"; `viewer_clear_marks` reads "Clear marks".
    static func verb(_ row: ToolRow) -> String {
        let name = row.tool.dropFirst(prefix.count).replacingOccurrences(of: "_", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The latest step, as "Click · Start trail".
    static func latest(_ rows: [ToolRow]) -> String {
        guard let last = rows.last else { return "" }
        let summary = ToolRowPresentation(row: last).summaryText
        return summary.map { "\(verb(last)) · \($0)" } ?? verb(last)
    }

    static func live(_ rows: [ToolRow]) -> Bool { rows.contains { !$0.finished } }

    /// A step refused, failed or declined: the folded row's mark turns red.
    static func troubled(_ rows: [ToolRow]) -> Bool {
        rows.contains { $0.ok == false || $0.permission == .declined || $0.permission == .blocked }
    }

    static func title(_ rows: [ToolRow]) -> String { live(rows) ? "Using the viewer" : "Used the viewer" }

    static func count(_ rows: [ToolRow]) -> String { rows.count == 1 ? "1 step" : "\(rows.count) steps" }
}

/// One drawn entry: an item, or a folded run of viewer steps at a reply's width.
struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    var folder: String? = nil
    var chat: Int? = nil
    @Environment(\.conversationColumn) private var column

    var body: some View {
        switch entry {
        case .item(let item):
            TranscriptItemView(item: item, folder: folder, chat: chat)
        case .viewerSteps(let rows):
            ViewerStepsView(rows: rows, folder: folder, chat: chat)
                .frame(maxWidth: column.map(ConversationColumn.replyWidth) ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A run of viewer steps as one row; the chevron opens the steps (AL5).
struct ViewerStepsView: View {
    let rows: [ToolRow]
    var folder: String? = nil
    var chat: Int? = nil
    @EnvironmentObject private var model: AppModel
    @State private var open = false

    private func waiting(_ row: ToolRow) -> Bool {
        chat.map { model.permissionCard(chat: $0, toolUseId: row.toolUseId) != nil } ?? false
    }

    var body: some View {
        // A step waiting for the person's OK opens the run, so the ask is seen.
        let shown = open || rows.contains(where: waiting)
        VStack(alignment: .leading, spacing: TranscriptSpacing.toolRowGap) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    mark.frame(width: 14, height: 14)
                    Text(ViewerSteps.title(rows))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                    Text(ViewerSteps.count(rows))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.surface, in: Capsule())
                    Text(ViewerSteps.latest(rows))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: shown ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .accessibilityLabel("\(ViewerSteps.title(rows)), \(ViewerSteps.count(rows)), latest \(ViewerSteps.latest(rows))")
            .accessibilityHint(shown ? "Hide the steps" : "Show the steps")
            if shown {
                VStack(alignment: .leading, spacing: TranscriptSpacing.toolRowGap) {
                    ForEach(rows, id: \.toolUseId) { row in
                        ToolRowView(row: row, folder: folder, waiting: waiting(row))
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        if ViewerSteps.troubled(rows) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.deny)
        } else if ViewerSteps.live(rows) {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.working)
        }
    }
}
