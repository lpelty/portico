import SwiftUI

/// How one tool call reads as a row: the icon for the tool, the state
/// line (running, the finish summary, or the failure), and the input as
/// pretty JSON for the disclosure. View-free so it can be tested.
struct ToolRowPresentation: Equatable {
    let row: ToolRow

    init(row: ToolRow) {
        self.row = row
    }

    /// The one icon every tool row wears. A tool's name is data the agent
    /// reports, not something the app knows (spec section 3: no
    /// special-casing a tool name); the name and summary carry the meaning.
    static let toolIcon = "wrench.and.screwdriver"

    var icon: String { Self.toolIcon }

    /// `running` until the finish arrives; then the finish summary, or
    /// `failed: <summary>` when the call did not go well.
    var stateText: String {
        guard row.finished else { return "running" }
        let result = row.result ?? ""
        if row.ok == false {
            return result.isEmpty ? "failed" : "failed: \(result)"
        }
        return result.isEmpty ? "done" : result
    }

    /// The tool's input, keys sorted, two-space indented.
    var prettyInput: String {
        PrettyJSON.render(row.input)
    }
}

/// One tool call, folded: icon, tool name, what it touched, and its state
/// at the trailing edge. Disclosing it shows the input as JSON and, once
/// finished, the result line.
struct ToolRowView: View {
    let row: ToolRow
    @State private var expanded = false

    private var shown: ToolRowPresentation { ToolRowPresentation(row: row) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(shown.prettyInput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                if row.finished {
                    Label(shown.stateText, systemImage: row.ok == false ? "xmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(row.ok == false ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: shown.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(row.tool)
                    .fontWeight(.medium)
                Text(row.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                trailing
            }
            .font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .help(shown.stateText)
    }

    @ViewBuilder
    private var trailing: some View {
        if !row.finished {
            ProgressView()
                .controlSize(.mini)
        } else if row.ok == false {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
