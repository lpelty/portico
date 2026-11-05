import SwiftUI

/// Which kind of run a fold is: every step the viewer's, or any tools (v0.19 §7).
enum ToolRunKind: Equatable { case viewer, any }

/// How many tool rows in a row fold into one (v0.19 §7). A run made only of
/// the viewer's steps keeps its own, lower, bar.
enum ToolRun {
    static let threshold = 3
    static let viewerThreshold = 2
}

/// What the conversation draws, item by item, with runs of tool rows folded
/// into one entry (v0.13 decision 8, Pen AL5; v0.19 §7 widens it to any tool).
enum TranscriptEntry: Identifiable, Equatable {
    case item(TranscriptItem)
    /// A run of tool rows; the id is the first row's, so it stays the same
    /// while the run grows.
    case toolRun(ToolRunKind, [ToolRow])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .toolRun(_, let rows): "tool-run:\(rows.first?.toolUseId ?? "")"
        }
    }

    /// A tool row, or a run of them: what closes up against its neighbours (decision 1).
    var isToolRow: Bool {
        switch self {
        case .item(let item): if case .tool = item { return true }; return false
        case .toolRun: return true
        }
    }

    /// Rows that never fold in: the question's record and the Mark row
    /// stand alone. `apart` adds the rows only the model knows (a thread
    /// proposal's card, an app's page); each splits the run around it.
    static func standsApart(_ row: ToolRow) -> Bool {
        QuestionRecord.isRecord(row) || row.tool == ViewerSteps.markTool
    }

    /// `items` with each run of tool rows folded: three or more, or two or
    /// more when every row is a viewer step.
    static func entries(_ items: [TranscriptItem], apart: (ToolRow) -> Bool = { _ in false }) -> [TranscriptEntry] {
        var out: [TranscriptEntry] = []
        var run: [ToolRow] = []
        func flush(next: Int) {
            // A turn that ended or moved on leaves no step running (a stopped
            // turn never finishes its rows): the run reads as done.
            if let last = run.last, run.contains(where: { !$0.finished }),
                items[next...].contains(where: { later(than: last.turn, $0) })
            {
                run = run.map { var r = $0; r.finished = true; return r }
            }
            let viewer = !run.isEmpty && run.allSatisfy(ViewerSteps.isStep)
            if viewer && run.count >= ToolRun.viewerThreshold {
                out.append(.toolRun(.viewer, run))
            } else if run.count >= ToolRun.threshold {
                out.append(.toolRun(.any, run))
            } else {
                out += run.map { .item(.tool($0)) }
            }
            run = []
        }
        for (index, item) in items.enumerated() {
            if case .tool(let row) = item, !standsApart(row), !apart(row) {
                run.append(row)
            } else {
                flush(next: index)
                out.append(.item(item))
            }
        }
        flush(next: items.count)
        return out
    }

    /// Whether `item` closes or follows the turn `turn`: its marker, or a
    /// message of a later turn.
    private static func later(than turn: Int, _ item: TranscriptItem) -> Bool {
        switch item {
        case .turnMarker(let marker): marker.turn >= turn
        case .userText(let user): user.turn > turn
        case .tool(let row): row.turn > turn
        default: false
        }
    }

    /// An anchor saved on a row now folded into a run restores at the run.
    static func anchor(_ id: String, in entries: [TranscriptEntry]) -> String? {
        if entries.contains(where: { $0.id == id }) { return id }
        return entries.first { entry in
            if case .toolRun(_, let rows) = entry { return rows.contains { "tool:\($0.toolUseId)" == id } }
            return false
        }?.id
    }
}

/// Which folded runs the person opened, kept for the session by the chat
/// and the run's id (the first row's), on the conversation, not the row.
@MainActor
final class ToolRunFolds: ObservableObject {
    static let shared = ToolRunFolds()
    @Published private(set) var open: Set<String> = []

    nonisolated static func key(chat: Int?, id: String) -> String { "\(chat.map(String.init) ?? "main")|\(id)" }

    func isOpen(_ key: String) -> Bool { open.contains(key) }

    func toggle(_ key: String) {
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.open.contains(key) }, set: { if $0 { self.open.insert(key) } else { self.open.remove(key) } })
    }
}

/// A run's folded row as it reads: the title, the summary of what ran, and
/// the newest step while it runs. View-free so it can be tested.
enum ToolRunPresentation {
    static func running(_ rows: [ToolRow]) -> Bool { rows.contains { !$0.finished } }

    static func title(kind: ToolRunKind, running: Bool, count: Int) -> String {
        if kind == .viewer { return running ? "Using the viewer" : "Used the viewer" }
        let steps = count == 1 ? "1 step" : "\(count) steps"
        return running ? "Working \u{B7} \(steps)" : "Ran \(steps)"
    }

    /// "Bash ×5 · Read ×2": the tools by count, then first appearance; a
    /// tool used once has no count; three tools at most, then " · +N" more.
    static func summary(_ rows: [ToolRow]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for row in rows {
            let name = ToolRowPresentation.title(for: row.tool)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let ranked = order.enumerated()
            .sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
            .map(\.element)
        var parts = ranked.prefix(3).map { name -> String in
            let n = counts[name] ?? 0
            return n > 1 ? "\(name) \u{D7}\(n)" : name
        }
        if ranked.count > 3 { parts.append("+\(ranked.count - 3)") }
        return parts.joined(separator: " \u{B7} ")
    }

    /// The failed, declined and blocked rows, in order: drawn under a folded group.
    static func outside(_ rows: [ToolRow]) -> [ToolRow] {
        rows.filter { $0.ok == false || $0.permission == .declined || $0.permission == .blocked }
    }

    static func troubled(_ rows: [ToolRow]) -> Bool { !outside(rows).isEmpty }

    /// The newest row's line while a group runs: "Read · src/app.ts".
    static func latest(_ rows: [ToolRow], kind: ToolRunKind) -> String {
        // The newest step that is still going (tools run in parallel), else the last.
        guard let last = rows.last(where: { !$0.finished }) ?? rows.last else { return "" }
        if kind == .viewer { return ViewerSteps.latest([last]) }
        let name = ToolRowPresentation.title(for: last.tool)
        return ToolRowPresentation(row: last).summaryText.map { "\(name) \u{B7} \($0)" } ?? name
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

/// One drawn entry: an item, or a folded run of tool rows at a reply's width.
struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    var folder: String? = nil
    var chat: Int? = nil
    @ObservedObject private var folds = ToolRunFolds.shared
    @Environment(\.conversationColumn) private var column

    var body: some View {
        switch entry {
        case .item(let item):
            TranscriptItemView(item: item, folder: folder, chat: chat)
        case .toolRun(let kind, let rows):
            ToolRunView(
                kind: kind, rows: rows, folder: folder, chat: chat,
                open: folds.binding(ToolRunFolds.key(chat: chat, id: entry.id)))
                .frame(maxWidth: column.map(ConversationColumn.replyWidth) ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A run of tool rows as one row; the chevron opens the steps (AL5, v0.19 §7).
/// Open or closed is the view's own, kept under the first row's id (the
/// entry's id) for as long as the chat draws it.
struct ToolRunView: View {
    let kind: ToolRunKind
    let rows: [ToolRow]
    var folder: String? = nil
    var chat: Int? = nil
    @EnvironmentObject private var model: AppModel
    @Binding var open: Bool

    private func waiting(_ row: ToolRow) -> Bool {
        chat.map { model.permissionCard(chat: $0, toolUseId: row.toolUseId) != nil } ?? false
    }

    var body: some View {
        // A step waiting for the person's OK opens the run, so the ask is seen.
        let shown = open || rows.contains(where: waiting)
        let running = ToolRunPresentation.running(rows)
        let title = ToolRunPresentation.title(kind: kind, running: running, count: rows.count)
        let latest = ToolRunPresentation.latest(rows, kind: kind)
        let summary = kind == .viewer ? ViewerSteps.count(rows) : ToolRunPresentation.summary(rows)
        VStack(alignment: .leading, spacing: TranscriptSpacing.toolRowGap) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { open.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        mark.frame(width: 14, height: 14)
                        Text(title)
                            .scaledFont(13, weight: .medium)
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                        if kind == .viewer {
                            Text(summary)
                                .scaledFont(11, monospacedDigit: true)
                                .foregroundStyle(Theme.text2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.surface, in: Capsule())
                            Text(latest)
                                .scaledFont(13)
                                .foregroundStyle(Theme.text3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if !running {
                            Text(summary)
                                .scaledFont(13)
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: shown ? "chevron.down" : "chevron.right")
                            .font(Theme.iconFont(10, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                    }
                    if kind == .any, running, !shown, !latest.isEmpty {
                        Text(latest)
                            .scaledFont(13)
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 22)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .accessibilityLabel(kind == .viewer
                ? "\(title), \(summary), latest \(latest)"
                : "\(title), \(summary)\(running && !latest.isEmpty ? ", latest \(latest)" : "")")
            .accessibilityHint(shown ? "Hide the steps" : "Show the steps")
            if shown {
                VStack(alignment: .leading, spacing: TranscriptSpacing.toolRowGap) {
                    ForEach(rows, id: \.toolUseId) { row in
                        ToolRowView(row: row, folder: folder, waiting: waiting(row))
                    }
                }
                .padding(.leading, 22)
            } else if kind == .any {
                // A failure stays out where it is seen, as its own row.
                VStack(alignment: .leading, spacing: TranscriptSpacing.toolRowGap) {
                    ForEach(ToolRunPresentation.outside(rows), id: \.toolUseId) { row in
                        ToolRowView(row: row, folder: folder, waiting: waiting(row))
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        if ToolRunPresentation.troubled(rows) {
            Image(systemName: "xmark").font(Theme.iconFont(11, weight: .semibold)).foregroundStyle(Theme.deny)
        } else if ToolRunPresentation.running(rows) {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "checkmark").font(Theme.iconFont(11, weight: .semibold)).foregroundStyle(Theme.working)
        }
    }
}
