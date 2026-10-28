import SwiftUI

/// The single-session sidebar's upper part, frames "S1 · Session card +
/// earlier" and "S2 · The nudge": THIS SESSION (the live session's card,
/// which turns into the amber nudge when the session is long), then
/// EARLIER (ended sessions, newest first, searchable by title, in a list
/// whose height is dragged at the line under it and remembered).
struct SessionSidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: Settings
    @State private var searching = false
    @State private var query = ""
    /// The list's height when its divider drag began.
    @State private var dragStart: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionLabel("This session")
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            if let live = model.liveSession {
                SessionCard(summary: live)
                    .padding(.horizontal, 8)
            } else {
                Text("No session yet. Say something to start one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 16)
            }
            earlier
        }
    }

    // MARK: EARLIER

    @ViewBuilder
    private var earlier: some View {
        let all = model.earlierSessions(matching: searching ? query : "")
        if !model.earlierSessions.isEmpty {
            HStack(spacing: 8) {
                SidebarSectionLabel("Earlier")
                Spacer(minLength: 0)
                Button {
                    searching.toggle()
                    if !searching { query = "" }
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help(searching ? "Stop searching" : "Search earlier sessions by title")
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)
            if searching {
                TextField("Search titles", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            let height = ColumnWidths.earlierHeight(dragged: settings.earlierHeight, sessions: all.count)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(all, id: \.chat) { summary in
                        EarlierRow(summary: summary, selected: model.selected == summary.chat) {
                            model.open(chat: summary.chat)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: all.isEmpty ? 0 : height)
            if searching && all.isEmpty {
                Text("No session titled “\(query)”")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 16)
            }
            // Drag to show more or fewer earlier sessions; the files take the rest.
            ColumnDivider(
                axis: .horizontal,
                onDrag: { dy in
                    let start = dragStart ?? height
                    dragStart = start
                    settings.earlierHeight = ColumnWidths.clampEarlier(start + dy)
                },
                onEnd: { dragStart = nil },
                onReset: { settings.earlierHeight = nil })
                .padding(.top, 6)
        }
    }
}

/// One ended session: number, title, logged check / not-logged amber dot /
/// nothing when unknown, and when it ended. A click opens it read-only.
struct EarlierRow: View {
    let summary: ChatSummary
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shown = SessionPresentation(summary: summary)
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(summary.chat)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.text3)
                    .frame(minWidth: 18, alignment: .leading)
                Text(shown.title ?? "Untitled")
                    .font(.system(size: 13))
                    .foregroundStyle(shown.title == nil ? Theme.text3 : Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                loggedMark
                Text(SessionTime.parse(summary.ended ?? summary.created).map { SessionTime.relativeDay($0) } ?? "")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(summary.logged == true ? "Logged" : summary.logged == false ? "Not logged" : "")
    }

    @ViewBuilder
    private var loggedMark: some View {
        switch summary.logged {
        case true?:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text3)
        case false?:
            Circle().fill(Theme.wait).frame(width: 6, height: 6)
        case nil:
            EmptyView()
        }
    }
}

/// The live session's card (S1), or the nudge (S2) when the session is
/// long: amber, the sentence, primary "Log and start new" and "Not now".
struct SessionCard: View {
    let summary: ChatSummary
    @EnvironmentObject private var model: AppModel

    private var chat: Int { summary.chat }
    private var nudging: Bool { model.shouldNudge(chat: chat) }
    private var renewing: Bool { model.isRenewing(chat: chat) }
    private var canLog: Bool { model.hello?.canLog == true }
    private var renewLabel: String { canLog ? "Log and start new" : "Start new" }

    var body: some View {
        let shown = SessionPresentation(summary: summary)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 7, height: 7)
                Text(shown.number)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if let start = SessionTime.parse(summary.created) {
                    // Re-reads the clock each minute so the age moves.
                    TimelineView(.everyMinute) { context in
                        Text(SessionTime.age(since: start, now: context.date))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
            if nudging {
                Text(nudgeSentence)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(shown.startedLine())
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            contextRow
            buttons
            if !nudging && model.canRenew(chat: chat) {
                Text("Same as typing \(AppModel.renewCommand)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(12)
        .background(nudging ? Theme.waitSoft : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(nudging ? Theme.wait : Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// The frame's sentence, saying what made the session long.
    private var nudgeSentence: String {
        let count = model.compactions(for: chat)
        let summarized = count >= AppModel.nudgeCompactions
            ? " and has been summarized \(count == 2 ? "twice" : "\(count) times")" : ""
        let log = canLog ? "Log it and start fresh" : "Start fresh"
        return "This session is long\(summarized). \(log) to keep answers sharp."
    }

    @ViewBuilder
    private var contextRow: some View {
        if let percent = model.contextPercent(for: chat) {
            let compactions = model.compactions(for: chat)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(compactions > 0 ? "Context · summarized \(compactions)×" : "Context")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                    Spacer(minLength: 0)
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 12, weight: nudging ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(nudging ? Theme.wait : Theme.text2)
                }
                ContextMeter(percent: percent, color: nudging ? Theme.wait : Theme.meterFill)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if model.canRenew(chat: chat) {
            if nudging {
                HStack(spacing: 8) {
                    Button(action: renew) { renewButtonLabel }
                        .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    Button("Not now") { model.dismissNudge(chat: chat) }
                        .buttonStyle(.hoverText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                }
                .disabled(renewing || model.connection != .connected)
            } else {
                Button(action: renew) {
                    renewButtonLabel.frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .disabled(renewing || model.connection != .connected)
                .help(canLog ? "Log this session, then start the next" : "End this session and start the next")
            }
        }
    }

    private var renewButtonLabel: some View {
        HStack(spacing: 6) {
            if renewing {
                ProgressView().controlSize(.mini)
                Text(canLog ? "Logging…" : "Starting…")
            } else {
                Image(systemName: canLog ? "square.and.pencil" : "plus")
                Text(renewLabel)
            }
        }
    }

    private func renew() {
        model.renew(chat: chat)
    }

    private var stateColor: Color {
        switch summary.state {
        case .idle: Theme.working
        case .working: Theme.working
        case .waitingOnYou: Theme.wait
        case .stopped: Theme.stopped
        }
    }
}

/// The card's thin context meter: a track and a fill to `percent`.
struct ContextMeter: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.meterTrack)
                Capsule().fill(color)
                    .frame(width: proxy.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: Theme.meterHeight)
        .accessibilityLabel("Context \(Int(percent.rounded())) percent")
    }
}
