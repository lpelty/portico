import SwiftUI

/// A CSV or TSV file as a table (X1). The file is read and parsed off the
/// main thread behind a brief "Loading…"; one that doesn't parse into a
/// consistent shape shows as monospaced text instead.
struct TablePane: View {
    let file: URL
    let separator: Character
    let shown: ArtifactPresentation
    @State private var load: TableLoad?

    var body: some View {
        Group {
            switch load {
            case nil:
                LoadingPane()
            case .table(let table, let widths, let note)?:
                TableBody(table: table, widths: widths, note: note, file: file)
            case .text(let read)?:
                TextBody(read: read, file: file)
            case .unreadable?:
                OtherPane(shown: shown, message: "Portico can't read this file as text. Open it in the app that can.")
            }
        }
        .task(id: file) {
            let file = file
            let separator = separator
            let result = await offMain { TableLoad.load(file, separator: separator) }
            guard !Task.isCancelled else { return }
            load = result
        }
    }
}

/// Runs `work` off the main thread and waits for it; when the waiting task
/// is cancelled (the view went away, another file was picked) the work is
/// cancelled too. A detached task doesn't inherit cancellation on its own,
/// so without this every big file clicked past kept parsing.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let task = Task.detached(operation: work)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// The table itself. The header row stays put while the rows scroll down,
/// and moves with them when a wide table scrolls sideways: one scroll view
/// scrolls both ways (so both scrollers sit at the viewer's edges, however
/// wide the table), and the header is the pinned header of the one section
/// in a lazy stack. Rows draw lazily on fixed column widths, so tens of
/// thousands scroll smoothly. At most `DelimitedTable.maxDrawnColumns`
/// columns draw: one width per drawn column.
///
/// Header semibold on the surface colour; hairlines between rows; numeric
/// columns right-aligned; a cell wider than its column truncates. Cells
/// select and copy.
struct TableBody: View {
    let table: DelimitedTable
    let widths: [CGFloat]
    let note: String?
    /// The file shown, for the agent (v0.12); `nil` draws the table alone.
    var file: URL? = nil
    @Environment(\.viewerAgent) private var agent
    @State private var seen = TableRowsSeen()

    static let rowHeight: CGFloat = 30

    private var tableWidth: CGFloat { widths.reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(0..<table.rows.count, id: \.self) { index in
                                row(table.rows[index], header: false)
                                    // Which rows are on screen, for the agent (v0.12).
                                    .onScrollVisibilityChange(threshold: 0.5) { seen.set(index, visible: $0) }
                                hairline
                            }
                        } header: {
                            VStack(spacing: 0) {
                                row(table.header, header: true)
                                hairline
                            }
                        }
                    }
                    .textSelection(.enabled)
                    // The content's own size, so the agent reads which rows are visible.
                    .background {
                        if let agent, let file { TableContentAnchor(agent: agent, file: file, table: table, seen: seen) }
                    }
                    // As wide as the table, or the viewer when that is wider;
                    // at least as tall as the viewer so a short table sits at the top.
                    .frame(width: max(tableWidth, geo.size.width), alignment: .topLeading)
                    .frame(minHeight: geo.size.height, alignment: .topLeading)
                }
            }
            if let note {
                ViewerFootnote(text: note)
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<widths.count, id: \.self) { column in
                Text(column < cells.count ? cells[column] : "")
                    .font(.system(size: DelimitedTable.fontSize, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? Theme.text2 : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, DelimitedTable.cellPadding)
                    .frame(width: widths[column], alignment: table.numeric[column] ? .trailing : .leading)
            }
        }
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The pinned header is opaque so rows scrolling under it don't show.
        .background(header ? Theme.surface : .clear)
    }
}

/// A view as big as a table's content, given to the agent: its visible
/// rect says which rows are on screen, and its scroll view scrolls them.
struct TableContentAnchor: NSViewRepresentable {
    let agent: ViewerAgent
    let file: URL
    let table: DelimitedTable
    let seen: TableRowsSeen

    final class Content: NSView {
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Content()
        agent.attachNative(view, file: file, table: table, rows: seen, slot: context.environment.viewerSlot)
        return view
    }

    /// The same view drawn for another file or table (SwiftUI keeps a
    /// view when only its inputs change): the agent reads the new one.
    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.file != file || context.coordinator.table != table else { return }
        context.coordinator.file = file
        context.coordinator.table = table
        agent.attachNative(view, file: file, table: table, rows: seen, slot: context.environment.viewerSlot)
    }

    func makeCoordinator() -> Shown { Shown(file: file, table: table) }

    /// What the view was last given to the agent as.
    final class Shown {
        var file: URL
        var table: DelimitedTable
        init(file: URL, table: DelimitedTable) {
            self.file = file
            self.table = table
        }
    }
}

/// The table rows on screen, as the rows report it (a lazy stack's height
/// is an estimate until rows draw, so a position can't say which rows).
/// Read by the agent; not drawn, so not published.
@MainActor
final class TableRowsSeen {
    private(set) var visible: Set<Int> = []

    func set(_ row: Int, visible shown: Bool) {
        if shown { visible.insert(row) } else { visible.remove(row) }
    }
}
