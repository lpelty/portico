import SwiftUI

/// One composer's slash list (v0.11 item 66): the selected row and whether
/// Esc closed it. Esc keeps it closed until the text stops being a `/`
/// and a name, so typing on after Esc does not bring it back.
struct SlashListState: Equatable {
    var selection = 0
    var dismissed = false

    /// The list for `text`, unless Esc closed it.
    func completion(text: String, agentCommands: [AgentCommand]) -> SlashCompletion? {
        dismissed ? nil : SlashCompletion(text: text, agentCommands: agentCommands)
    }

    /// The typed name changed (`query`, `nil` when the text is no longer a
    /// slash name): back to the first row, and Esc forgotten once it is gone.
    mutating func queryChanged(to query: String?) {
        selection = 0
        if query == nil { dismissed = false }
    }

    /// Apply a key's outcome. Returns the row picked (and whether to send),
    /// which the composer acts on; a move or a close is kept here.
    mutating func apply(_ outcome: SlashCompletion.Outcome) -> (item: SlashCompletion.Item, send: Bool)? {
        switch outcome {
        case .select(let row):
            selection = row
            return nil
        case .close:
            dismissed = true
            return nil
        case .pick(let item, let send):
            return (item, send)
        }
    }
}

extension SlashCompletion.Key {
    /// The list's keys as SwiftUI names them; `nil` for any other key.
    init?(_ key: KeyEquivalent) {
        switch key {
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .tab: self = .tab
        case .return: self = .enter
        case .escape: self = .escape
        default: return nil
        }
    }
}

/// The slash list over a composer, frame AG4 (v0.11 item 66): a PORTICO
/// group (/log, /new), then "<AGENT> — SKILLS AND COMMANDS", a row per
/// command with its one-line description, the selected row tinted with ↵
/// at its end, and a footer with the count and the keys. It scrolls past
/// `SlashCompletion.visibleRows`; ↑/↓ keep the selection in view. A click
/// picks the row as Enter would.
struct SlashCommandList: View {
    let completion: SlashCompletion
    let selection: Int
    let agentName: String
    let pick: (SlashCompletion.Item) -> Void

    static let rowHeight: CGFloat = 29
    static let headerHeight: CGFloat = 26
    static let nameWidth: CGFloat = 122

    /// Tall enough for every row up to `visibleRows`, plus the group headers.
    private var listHeight: CGFloat {
        let rows = CGFloat(min(completion.items.count, SlashCompletion.visibleRows))
        let headers = CGFloat((completion.portico.isEmpty ? 0 : 1) + (completion.agent.isEmpty ? 0 : 1))
        return rows * Self.rowHeight + headers * Self.headerHeight + 12
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !completion.portico.isEmpty {
                            header("Portico")
                            rows(completion.portico, offset: 0)
                        }
                        if !completion.agent.isEmpty {
                            header("\(agentName) — Skills and commands")
                            rows(completion.agent, offset: completion.portico.count)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.automatic)
                .frame(height: listHeight)
                .onChange(of: selection) { _, new in
                    let items = completion.items
                    if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                Text(completion.footer)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(SlashCompletion.keyHints)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.text3)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: Self.headerHeight, alignment: .bottomLeading)
            .padding(.bottom, 2)
    }

    private func rows(_ items: [SlashCompletion.Item], offset: Int) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            row(item, selected: offset + index == selection)
                .id(item.id)
                .onTapGesture { pick(item) }
        }
    }

    private func row(_ item: SlashCompletion.Item, selected: Bool) -> some View {
        HStack(spacing: 14) {
            Text("/\(item.name)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: Self.nameWidth, alignment: .leading)
                // The name wins the row; a long description is the one cut.
                .layoutPriority(1)
            Text(item.description)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if selected {
                Text("↵")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(item.description.isEmpty ? "/\(item.name)" : "/\(item.name) — \(item.description)")
    }
}

extension View {
    /// Show `list` just above this view (the composer), over what is there,
    /// when there is one (v0.11 item 66).
    func slashList<List: View>(@ViewBuilder _ list: () -> List) -> some View {
        overlay(alignment: .top) {
            list()
                .alignmentGuide(.top) { d in d[.bottom] + 8 }
        }
    }
}
