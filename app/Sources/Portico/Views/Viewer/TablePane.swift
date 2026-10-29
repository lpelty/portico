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
                TableBody(table: table, widths: widths, note: note)
            case .text(let read)?:
                TextBody(read: read)
            case .unreadable?:
                OtherPane(shown: shown, message: "Portico can't read this file as text. Open it in the app that can.")
            }
        }
        .task(id: file) {
            let file = file
            let separator = separator
            load = await Task.detached { TableLoad.load(file, separator: separator) }.value
        }
    }
}

/// The table itself. The header row stays put while the rows scroll down,
/// and moves with them when a wide table scrolls sideways: one horizontal
/// scroll view holds the header and a vertical one under it. Rows draw
/// lazily on fixed column widths, so tens of thousands scroll smoothly.
///
/// Header semibold on the surface colour; hairlines between rows; numeric
/// columns right-aligned; a cell wider than its column truncates. Cells
/// select and copy.
struct TableBody: View {
    let table: DelimitedTable
    let widths: [CGFloat]
    let note: String?

    static let rowHeight: CGFloat = 30

    private var tableWidth: CGFloat { widths.reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        row(table.header, header: true)
                        hairline
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<table.rows.count, id: \.self) { index in
                                    row(table.rows[index], header: false)
                                    hairline
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(width: max(tableWidth, geo.size.width), height: geo.size.height, alignment: .topLeading)
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
        .background(header ? Theme.surface : .clear)
    }
}
