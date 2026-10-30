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

    /// The tool's name as the row reads it (v0.11, item 59). An MCP tool's
    /// id (`mcp__memory__query_documents`) reads `memory · query documents`:
    /// the server, then the tool with its underscores as spaces. The
    /// `mcp__<server>__<tool>` shape is the engine's naming, not a tool the
    /// app knows. Any other name reads as it came.
    static func title(for tool: String) -> String {
        let prefix = "mcp__"
        guard tool.hasPrefix(prefix) else { return tool }
        let rest = tool.dropFirst(prefix.count)
        guard let split = rest.range(of: "__"), split.lowerBound > rest.startIndex else { return tool }
        let server = rest[..<split.lowerBound]
        let name = rest[split.upperBound...].replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return tool }
        return "\(server) · \(name)"
    }

    var title: String { Self.title(for: row.tool) }

    /// What the row shows after the title: the start's summary, or nothing
    /// when it only repeats the tool's id (an MCP tool with no better
    /// summary, which read `mcp__x__y mcp__x__y` before v0.11).
    var summaryText: String? {
        let summary = row.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty || summary == row.tool ? nil : row.summary
    }

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

    /// How the row's end reads (V1): `waiting for your OK` while its
    /// permission card is open, then what became of the permission —
    /// `allowed once`, `allowed for this session`, `auto`, `declined`,
    /// `blocked by auto mode` — or `not answered` when the gateway cancelled
    /// the card. `nil`: nothing was asked (a read in Ask each time).
    func outcomeText(waiting: Bool) -> String? {
        if waiting { return "waiting for your OK" }
        switch row.permission {
        case .once: return "allowed once"
        case .session: return "allowed for this session"
        case .auto: return "auto"
        case .declined: return "declined"
        case .blocked: return "blocked by auto mode"
        case nil: return row.unanswered == nil ? nil : "not answered"
        }
    }

    enum Tone: Equatable { case wait, quiet, deny }

    /// The outcome's colour: the wait colour while asking, red for a
    /// refusal, quiet for an allow (it reads like any finished step).
    func outcomeTone(waiting: Bool) -> Tone {
        if waiting { return .wait }
        switch row.permission {
        case .declined, .blocked: return .deny
        default: return .quiet
        }
    }

    /// What a failed call said, on the row in the deny colour (v0.11, 59,
    /// AG7 option E: "exit 1 · not found"); `nil` unless it failed with words.
    var failureDetail: String? {
        guard row.finished, row.ok == false else { return nil }
        let result = (row.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// The line under a declined row: the note the person gave, if any.
    var noteLine: String? {
        guard row.permission == .declined, let note = row.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        return "Your note: \(note)"
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
///
/// v0.11 (59, AG7 option E): no fill and no border at rest, the panel fill
/// under the pointer (and while open, so the input reads on it); the name
/// in secondary text, what it touched in tertiary; the state icon keeps its
/// colour, and a failure's words follow on the row in the deny colour.
struct ToolRowView: View {
    let row: ToolRow
    var folder: String? = nil
    /// Its permission card is open (pinned above the composer).
    var waiting: Bool = false
    @State private var expanded = false
    @State private var hovering = false

    private var shown: ToolRowPresentation { ToolRowPresentation(row: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            box
            if let note = shown.noteLine {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                    Text(note)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                .foregroundStyle(Theme.text2)
                .padding(.leading, 30)
            }
        }
    }

    private var outcomeColor: Color {
        switch shown.outcomeTone(waiting: waiting) {
        case .wait: Theme.wait
        case .deny: Theme.deny
        case .quiet: Theme.text3
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    stateIcon
                        .frame(width: 14, height: 14)
                    Text(shown.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .help(row.tool)
                    if let summary = shown.summaryText {
                        Text(Self.display(summary, in: folder))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let failure = shown.failureDetail {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.deny)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    if let outcome = shown.outcomeText(waiting: waiting) {
                        Text(outcome)
                            .font(.system(size: 12))
                            .foregroundStyle(outcomeColor)
                            .lineLimit(1)
                            .fixedSize()
                            .help(row.unanswered ?? outcome)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            // The row's own fill answers the pointer (below), not a tint on the label.
            .buttonStyle(.plain)
            .pointerStyle(.link)
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
                        .foregroundStyle(row.ok == false ? Theme.deny : Theme.text2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(hovering || expanded ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help(shown.stateText)
    }

    @ViewBuilder
    private var stateIcon: some View {
        if waiting {
            Image(systemName: "hourglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.wait)
        } else if row.permission == .blocked {
            Image(systemName: "xmark.shield")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.deny)
        } else if row.permission == .declined {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.deny)
        } else if !row.finished {
            ProgressView()
                .controlSize(.mini)
        } else if row.ok == false {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.deny)
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
