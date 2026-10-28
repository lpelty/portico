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

/// One tool call, folded, as the frame's ToolLine: a state icon, the
/// tool's name, what it touched (relative to the chat's folder when it is
/// inside it), and a chevron. Disclosing it shows the input as JSON and,
/// once finished, the result line.
struct ToolRowView: View {
    let row: ToolRow
    var folder: String? = nil
    @State private var expanded = false

    private var shown: ToolRowPresentation { ToolRowPresentation(row: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    stateIcon
                        .frame(width: 14, height: 14)
                    Text(row.tool)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(Self.display(row.summary, in: folder))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(shown.prettyInput)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                if row.finished {
                    Text(shown.stateText)
                        .font(.system(size: 12))
                        .foregroundStyle(row.ok == false ? .red : Theme.text2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(shown.stateText)
    }

    @ViewBuilder
    private var stateIcon: some View {
        if !row.finished {
            ProgressView()
                .controlSize(.mini)
        } else if row.ok == false {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.working)
        }
    }

    /// `summary` with the chat's folder stripped when it names a path inside
    /// it (`/a/b/notes/x.md` in `/a/b` reads `notes/x.md`); display only.
    static func display(_ summary: String, in folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return summary }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        if summary.hasPrefix(prefix) { return String(summary.dropFirst(prefix.count)) }
        return summary.replacingOccurrences(of: prefix, with: "")
    }
}
