import SwiftUI

/// What the History row and popover say (v0.15, AN2): the row's count, the
/// popover's header, the sessions that match the search, and the empty line.
struct HistoryPresentation: Equatable {
    let sessions: [ChatSummary]
    let query: String

    var showsRow: Bool { !sessions.isEmpty }
    var rowCount: String { "\(sessions.count) earlier" }
    var header: String { "\(sessions.count) ended session\(sessions.count == 1 ? "" : "s")" }

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Sessions whose title, alias or number contains the query, in the order given.
    var shown: [ChatSummary] {
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { summary in
            [summary.title, summary.alias, String(summary.chat)].compactMap { $0 }
                .contains { $0.lowercased().contains(needle) }
        }
    }

    /// Set when a search matched nothing.
    var emptyMessage: String? {
        guard !needle.isEmpty, shown.isEmpty else { return nil }
        return "No session titled “\(query)”"
    }
}

/// The row where Earlier used to be: clock icon, "History", "N earlier",
/// chevron. It opens `HistoryPopover` to its right.
struct HistoryRow: View {
    let count: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.iconFont(14))
                    .foregroundStyle(Theme.text2)
                Text("History")
                    .scaledFont(13)
                    .foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
                Text(count)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
                Image(systemName: "chevron.right")
                    .font(Theme.iconFont(12))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
        .background(open ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .focusEffectDisabled()
        .help("Earlier sessions")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            HistoryPopover { open = false }
        }
    }
}

/// The ended sessions, newest first, with a title search focused on open.
/// A click opens one read-only and closes the popover; Esc closes it.
struct HistoryPopover: View {
    let close: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let history = HistoryPresentation(sessions: model.earlierSessions, query: query)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Text(history.header)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.iconFont(12))
                    .foregroundStyle(Theme.text3)
                TextField("Search titles", text: $query)
                    .textFieldStyle(.plain)
                    .scaledFont(12)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
            if let empty = history.emptyMessage {
                Text(empty)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(history.shown, id: \.chat) { summary in
                            EarlierRow(summary: summary, selected: model.selected == summary.chat) {
                                model.open(chat: summary.chat)
                                close()
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onExitCommand { close() }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }
}
