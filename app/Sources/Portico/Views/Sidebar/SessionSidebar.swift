import SwiftUI

/// The single-session sidebar's upper part, frames "S1 · Session card +
/// earlier" and "S2 · The nudge": THIS SESSION (the live session's card,
/// which turns into the amber nudge when the session is long), then the
/// History row (v0.15, AN2), which opens the ended sessions in a popover.
///
/// With threads on (v0.16 §9.6, AP4/AP5) the section is CONVERSATIONS: one
/// flat list, Main, Thread 1, Thread 2, where the row you're in is the
/// open card. With threads off it is the shipped single-session card.
struct SessionSidebar: View {
    @EnvironmentObject private var model: AppModel

    static func sectionLabel(threadsOn: Bool) -> String { threadsOn ? "Conversations" : "This session" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionLabel(Self.sectionLabel(threadsOn: model.threadsOn))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            if model.threadsOn, !model.sidebarThreads.rows(now: Date()).isEmpty {
                ConversationList()
                    .padding(.horizontal, 8)
            } else if let card = model.sidebarCard {
                SessionCard(summary: card)
                    .padding(.horizontal, 8)
            } else {
                Text("No session yet. Say something to start one.")
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 16)
            }
            earlier
        }
        .alert(closeQuestion, isPresented: closeConfirm) {
            Button("Close", role: .destructive) { model.confirmCloseThread() }
            Button("Cancel", role: .cancel) { model.closingThread = nil }
        }
    }

    /// "Thread 2 is still working. Close it anyway?" (`closingThread`).
    private var closeQuestion: String {
        ThreadsPresentation.closeQuestion(label: model.closingThread.flatMap { model.thread(of: $0)?.label } ?? "This thread")
    }

    private var closeConfirm: Binding<Bool> {
        Binding(get: { model.closingThread != nil }, set: { if !$0 { model.closingThread = nil } })
    }

    // MARK: HISTORY

    @ViewBuilder
    private var earlier: some View {
        let history = HistoryPresentation(sessions: model.earlierSessions, query: "")
        if history.showsRow {
            HistoryRow(count: history.rowCount)
                .padding(.horizontal, 8)
                .padding(.top, 14)
        }
    }
}

/// One ended session: number, title, logged check / not-logged amber dot /
/// nothing when unknown, and when it ended. A click opens it read-only.
/// Plain until hovered (v0.6, Y2): no box at rest, the hover tint, and
/// when selected the tint with a brighter, medium-weight title. No focus
/// ring: a clicked row must not keep the system's outline.
struct EarlierRow: View {
    let summary: ChatSummary
    let selected: Bool
    let action: () -> Void

    /// The title's colour and weight: brighter and medium when selected.
    static func titleStyle(selected: Bool, untitled: Bool) -> (color: Color, weight: Font.Weight) {
        // Drawn only in the History popover: its faint text is `text2` (v0.15 §5.7).
        if untitled { return (Theme.text2, selected ? .medium : .regular) }
        return selected ? (Theme.text, .medium) : (Theme.text2, .regular)
    }

    var body: some View {
        let shown = SessionPresentation(summary: summary)
        let title = Self.titleStyle(selected: selected, untitled: shown.historyTitle == nil)
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(summary.chat)")
                    .scaledFont(13, monospacedDigit: true)
                    .foregroundStyle(Theme.text2)
                    .frame(minWidth: 18, alignment: .leading)
                Text(shown.historyTitle ?? "Untitled")
                    .scaledFont(13, weight: title.weight)
                    .foregroundStyle(title.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                loggedMark
                if let when = SessionTime.parse(summary.ended ?? summary.created) {
                    CompactTime(date: when)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .focusEffectDisabled()
        .tip(summary.logged == true ? "Logged" : summary.logged == false ? "Not logged" : "")
    }

    @ViewBuilder
    private var loggedMark: some View {
        switch summary.logged {
        case true?:
            Image(systemName: "checkmark")
                .font(Theme.iconFont(10, weight: .semibold))
                .foregroundStyle(Theme.text3)
        case false?:
            Circle().fill(Theme.wait).frame(width: 6, height: 6)
        case nil:
            EmptyView()
        }
    }
}

/// The live session's card (S1, v0.4's W1): its commands, Log session
/// (disabled with the reason when the deployment cannot log, X2) and
/// New; or the nudge (S2) when the
/// session is long: amber, the sentence, primary "Log and start new" and
/// "Not now".
///
/// While something else has the main column (an earlier session, the
/// welcome, the document view) the card itself is a button to the live
/// session (v0.6, Y2): the hand and a stronger edge on hover, help "Go
/// back to Session M". Its own buttons keep their clicks, and the row
/// that holds them never passes a click to the card, even on a disabled
/// button (Log session or New while a log is out): only the rest of the
/// card opens the live session. VoiceOver reads it as "Show Session M" or
/// "Go back to Session M", a button only while it opens the session.
///
/// With threads on (§9.6) it is the open row of the conversation list:
/// the row's icon, name ("Main", "Thread 1") and subtitle, on the rows'
/// left edge; the two buttons share the row when they fit, else stack.
struct SessionCard: View {
    let summary: ChatSummary
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    private var chat: Int { summary.chat }
    /// Drawn as the conversation list's open row (threads on, §9.6).
    private var listed: Bool { model.threadsOn }

    /// The card's name: "Main" or "Thread 1" in the conversation list;
    /// with threads off, the shipped "Session N".
    static func title(summary: ChatSummary, threadsOn: Bool) -> String {
        if let label = summary.thread?.label { return label }
        return threadsOn ? "Main" : SessionPresentation(summary: summary).number
    }
    /// A thread's card (v0.16, AM3): Log session and Close thread, never New.
    private var info: ThreadInfo? { summary.thread }
    private var nudging: Bool { info == nil && model.shouldNudge(chat: chat) }
    private var renewing: Bool { model.isRenewing(chat: chat) }
    private var logging: Bool { model.isLogging(chat: chat) }
    private var pending: Bool { model.isSessionCommandPending(chat: chat) }
    private var canLog: Bool { model.canLog }
    private var canLogSession: Bool { model.canLogSession(chat: chat) }
    private var renewLabel: String { canLog ? "Log and start new" : "Start new" }

    /// The card opens the live session now.
    private var opensLive: Bool { model.cardOpensLiveSession(live: chat) }
    /// An earlier session is open: the card is the way back (Y2's hint).
    private var goesBack: Bool { opensLive && model.selected.map { model.isEnded(chat: $0) } == true }
    private var cardHelp: String {
        guard opensLive else { return "" }
        let name = Self.title(summary: summary, threadsOn: listed)
        return goesBack ? "Go back to \(name)" : "Show \(name)"
    }

    var body: some View {
        card
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .onTapGesture { if opensLive { model.openLiveSession(chat) } }
            .onHover { hovering = $0 }
            .pointerStyle(opensLive && hovering ? .link : nil)
            .tip(cardHelp)
            .modifier(OpensLiveAccessibility(label: opensLive ? cardHelp : nil) { model.openLiveSession(chat) })
    }

    /// The card as a button to VoiceOver, labelled and activated, only
    /// while a click on it opens the live session.
    private struct OpensLiveAccessibility: ViewModifier {
        let label: String?
        let action: () -> Void

        func body(content: Content) -> some View {
            if let label {
                content
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default) { action() }
            } else {
                content
            }
        }
    }

    private var card: some View {
        let shown = SessionPresentation(summary: summary)
        return VStack(alignment: .leading, spacing: 10) {
            if listed {
                listedTitleRow
            } else {
                HStack(spacing: 8) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(info?.label ?? shown.number)
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if let start = SessionTime.parse(summary.created) {
                        // Re-reads the clock each minute so the age moves.
                        TimelineView(.everyMinute) { context in
                            Text(SessionTime.age(since: start, now: context.date))
                                .scaledFont(12, monospacedDigit: true)
                                .foregroundStyle(Theme.text3)
                        }
                    }
                }
                if !nudging {
                    // Re-read each minute so "Started 12 min ago" moves (v0.7 decision 1).
                    TimelineView(.everyMinute) { context in
                        Text(shown.startedLine(now: context.date))
                            .scaledFont(12)
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            if nudging {
                Text(nudgeSentence)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            contextRow
            buttons
                // The buttons' row takes its own clicks: a disabled button
                // (or the gap between two) does nothing, not open the session.
                .contentShape(Rectangle())
                .onTapGesture {}
            if info != nil {
                threadFootnote
            } else if goesBack && !nudging {
                Text("Click to go back to it")
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
            } else if !nudging && model.canRenew(chat: chat) {
                Text(hint)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // In the list the card's content sits on the rows' left edge (§9.6).
        .padding(.horizontal, listed ? ConversationList.rowInset : 12)
        .padding(.vertical, listed ? 10 : 12)
        .background(nudging ? Theme.waitSoft : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            if opensLive && hovering {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.hoverTint)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(nudging ? Theme.wait : opensLive && hovering ? Theme.borderStrong : Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        // In the list (§9.6) the open card is the conversation you're in.
        .accessibilityAddTraits(listed ? .isSelected : [])
    }

    /// The open row's first line (§9.6): the icon, the name over its
    /// subtitle ("Session 4 · started 1:30 PM", a thread's title), and the
    /// spinner while it works, else the session's age.
    private var listedTitleRow: some View {
        HStack(spacing: 8) {
            ConversationIcon(isThread: info != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(summary: summary, threadsOn: true))
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                if let subtitle = listedSubtitle {
                    Text(subtitle)
                        .scaledFont(11)
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if summary.state == .working {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Working")
            } else if let start = SessionTime.parse(summary.created) {
                TimelineView(.everyMinute) { context in
                    Text(SessionTime.age(since: start, now: context.date))
                        .scaledFont(11, monospacedDigit: true)
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    /// Main's "Session 4 · started 1:30 PM"; a thread's title.
    private var listedSubtitle: String? {
        info == nil
            ? ThreadsPresentation.mainSubtitle(summary, open: true, calendar: .current, locale: .current)
            : SessionPresentation(summary: summary).title
    }

    /// The line under the buttons: what they do, and, when Log session is
    /// off, why (X2; v0.11 item 65).
    private var hint: String {
        AppModel.sessionCardHint(canLogSession: canLogSession, offReason: model.logSessionOffReason(chat: chat))
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
                        .scaledFont(12)
                        .foregroundStyle(Theme.text3)
                    Spacer(minLength: 0)
                    Text("\(Int(percent.rounded()))%")
                        .scaledFont(12, weight: nudging ? .semibold : .regular, monospacedDigit: true)
                        .foregroundStyle(nudging ? Theme.wait : Theme.text2)
                }
                ContextMeter(percent: percent, color: nudging ? Theme.wait : Theme.meterFill)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if info != nil {
            threadButtons
        } else if model.canRenew(chat: chat) {
            if nudging {
                HStack(spacing: 8) {
                    Button(action: renew) { renewButtonLabel }
                        .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    Button("Not now") { model.dismissNudge(chat: chat) }
                        .buttonStyle(.hoverText)
                        .scaledFont(13)
                        .foregroundStyle(Theme.text2)
                }
                .disabled(pending || model.connection != .connected)
            } else if listed {
                // §9.6: both labels keep their width; they share the row
                // when they fit it, else stack, as a thread's do.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        logSessionButton
                        newButton(keepsWidth: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        logSessionButton
                        newButton(keepsWidth: true)
                    }
                }
                .disabled(pending || model.connection != .connected)
            } else {
                HStack(spacing: 8) {
                    logSessionButton
                    newButton(keepsWidth: false)
                }
                .disabled(pending || model.connection != .connected)
            }
        }
    }

    /// The gap between a button's symbol and its words: tighter in the
    /// list, so Log session and Close thread share a 260-pt sidebar's row.
    private var labelGap: CGFloat { listed ? 4 : 6 }

    /// New: in the shipped card it gives way to Log session; in the list
    /// it keeps its width so the pair can stack instead (§9.6).
    private func newButton(keepsWidth: Bool) -> some View {
        Button { model.requestNew(chat: chat) } label: {
            HStack(spacing: labelGap) {
                if renewing {
                    ProgressView().controlSize(.mini)
                    Text("Starting…")
                } else {
                    Image(systemName: "plus")
                    Text("New")
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: keepsWidth, vertical: false)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(kind: .quiet, compact: keepsWidth))
        .tip("End this session and start the next")
    }

    /// Log session: shown even when it cannot log (disabled, the hint
    /// says why), so a missing log step is visible, not a mystery.
    private var logSessionButton: some View {
        Button { model.logSession(chat: chat) } label: {
            HStack(spacing: labelGap) {
                if logging {
                    ProgressView().controlSize(.mini)
                    Text("Logging…")
                } else {
                    Image(systemName: "square.and.pencil")
                    Text("Log session")
                }
            }
            .lineLimit(1)
            // Never "Log ses…": the label keeps its width, New gives way.
            .fixedSize()
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(kind: canLogSession ? .primary(model.brand.accent ?? Theme.accent) : .quiet, compact: listed))
        .disabled(!canLogSession)
        .tip(model.logSessionOffReason(chat: chat)
            ?? "Save what this session did, so the next one can pick up where it left off. The session goes on.")
    }

    /// A thread's Log session and Close thread (§2.5). Both labels keep
    /// their width (never "Close th…"), so the two share the row only when
    /// they fit it; otherwise they stack (§9.1). Two fixed-width labels in
    /// one row were wider than the 260-pt sidebar, and the card, wider
    /// than its column, pushed the sidebar's top section off its margin.
    private var threadButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                logSessionButton
                closeThreadButton
            }
            VStack(alignment: .leading, spacing: 6) {
                logSessionButton
                closeThreadButton
            }
        }
        .disabled(pending || model.connection != .connected)
    }

    private var closeThreadButton: some View {
        Button { model.requestCloseThread(chat: chat) } label: {
            HStack(spacing: labelGap) {
                if closing {
                    ProgressView().controlSize(.mini)
                    Text("Closing…")
                } else {
                    // A small ×, as drawn (AP4): the pair then shares the row at 100%.
                    Image(systemName: "xmark")
                        .font(Theme.iconFont(10, weight: .medium))
                    Text("Close thread")
                }
            }
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
        .tip("Close this thread; its summary goes to History")
        .disabled(closing)
    }

    /// The thread is being closed (its `thread.close`, or a Close and start).
    private var closing: Bool { model.isClosing(chat: chat) }

    /// "Close writes a summary to History"; after a refused close, why, and
    /// "Close without logging" when the log step could not start.
    @ViewBuilder
    private var threadFootnote: some View {
        if let failure = model.closeFailures[chat] {
            CloseFailureLine(chat: chat, failure: failure)
        } else {
            Text("Close writes a summary to History")
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
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

/// A compact time in a trailing column (v0.7 decision 1): re-read each
/// minute so "12 min ago" moves, with the full date and time as its tooltip.
struct CompactTime: View {
    let date: Date
    @Environment(\.inPopover) private var inPopover

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(SessionTime.compact(date, now: context.date))
                .scaledFont(11, monospacedDigit: true)
                .foregroundStyle(Theme.faintText(inPopover: inPopover))
                .lineLimit(1)
                .fixedSize()
                .tip(SessionTime.tooltip(date))
        }
    }
}
