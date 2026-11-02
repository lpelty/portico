import SwiftUI

// MARK: - Threads in the conversation (v0.16, AM1–AM4)

/// A thread's first message, drawn as its brief (AM3): "BRIEF FROM MAIN ·
/// 2:05 PM", the brief, and the files it started with.
struct BriefBlock: View {
    let info: ThreadInfo

    /// "BRIEF FROM MAIN · 2:05 PM"; without a time, "BRIEF FROM MAIN".
    static func heading(openedAt: Date?, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let openedAt else { return "BRIEF FROM MAIN" }
        return "BRIEF FROM MAIN · \(SessionTime.clock(openedAt, calendar: calendar, locale: locale))"
    }

    /// The transcript item drawn as the brief: a thread's first message,
    /// only when it is the brief (its text starts with it; attachments may
    /// be listed under it). Otherwise no item is replaced: a real message
    /// is never hidden under a brief block.
    static func briefItem(in items: [TranscriptItem], brief: String?) -> String? {
        let wanted = brief?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wanted.isEmpty,
            case .userText(let first)? = items.first(where: { if case .userText = $0 { true } else { false } })
        else { return nil }
        let text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix(wanted) ? TranscriptItem.userText(first).id : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.heading(openedAt: SessionTime.parse(info.openedAt)))
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Theme.text3)
                .tracking(0.4)
            Text(info.brief)
                .scaledFont(13)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !info.files.isEmpty {
                FileChips(paths: info.files)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The brief's files by name, as chips.
private struct FileChips: View {
    let paths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(Theme.iconFont(11))
                            .accessibilityHidden(true)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .scaledFont(12)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help(path)
                }
            }
        }
    }
}

/// The card drawn in place of Main's `open_thread` row (AM2, AM4): Start
/// thread / Not now; at the limit the open threads to pick one to close,
/// Close and start / Not now; afterwards the record, "Thread 1 started"
/// with Go to Thread 1 ⌃1 while that thread is open, or "Not started".
struct ProposalCard: View {
    let proposal: ThreadProposal
    @EnvironmentObject private var model: AppModel
    /// At the limit: the thread picked to close.
    @State private var pick: Int?
    /// The picked thread is working: "Thread 2 is still working. Close it anyway?".
    @State private var confirming = false

    var body: some View {
        let shown = model.proposalPresentation(for: proposal)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(Theme.iconFont(12))
                    .foregroundStyle(shown.record == nil ? model.brand.accent ?? Theme.accent : Theme.text3)
                    .accessibilityHidden(true)
                Text(shown.title)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(shown.record == nil ? Theme.text : Theme.text2)
            }
            switch shown.kind {
            case .offer:
                brief(shown)
                HStack(spacing: 8) {
                    Button("Start thread") { model.startThread(proposal, closing: nil) }
                        .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    notNow
                }
                .disabled(starting || model.connection != .connected)
            case .atLimit:
                Text("Closing writes its summary to History and the session log.")
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
                limitChoices
                limitCloseFailure
                HStack(spacing: 8) {
                    Button("Close and start", action: closeAndStart)
                        .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                        .disabled(pickedChoice == nil)
                    notNow
                }
                .disabled(starting || model.connection != .connected)
            case .started:
                brief(shown, quiet: true)
                if let label = shown.goLabel, let slot = shown.goSlot {
                    Button(label) { model.switchToConversation(slot: slot) }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .accessibilityLabel(model.thread(of: proposal.thread ?? -1).map {
                            ThreadsPresentation.spokenGoLabel(label: $0.label)
                        } ?? label)
                }
            case .notStarted:
                brief(shown, quiet: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .opacity(starting ? 0.6 : 1)
        .alert(confirmQuestion, isPresented: $confirming) {
            Button("Close", role: .destructive) {
                // The pick may have closed while the alert was up.
                guard let chat = pickedChoice else { return }
                start(closing: chat)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The `thread.start` is out: the card waits for the gateway.
    private var starting: Bool { model.startingProposal == proposal.proposal }

    private func brief(_ shown: ProposalPresentation, quiet: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shown.brief)
                .scaledFont(13)
                .foregroundStyle(quiet ? Theme.text2 : Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !quiet {
                Text(shown.takesLine)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private var notNow: some View {
        Button("Not now") { model.dismissProposal(proposal) }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .disabled(model.dismissingProposals.contains(proposal.proposal))
    }

    /// The open threads as a radio list (AM4).
    private var limitChoices: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 6) {
                ForEach(model.threads.limitChoices(now: context.date)) { choice in
                    let on = choice.chat == pick
                    Button { pick = choice.chat } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                .font(Theme.iconFont(13))
                                .foregroundStyle(on ? model.brand.accent ?? Theme.accent : Theme.text3)
                                .accessibilityHidden(true)
                            Text(choice.label)
                                .scaledFont(13, weight: .medium)
                                .foregroundStyle(Theme.text)
                            Text(choice.line)
                                .scaledFont(12)
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(on ? model.brand.accent ?? Theme.accent : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Thread to close")
        }
    }

    /// A Close and start whose close could not log: why, and Close without
    /// logging for that thread (as on its card).
    @ViewBuilder
    private var limitCloseFailure: some View {
        let failed = model.threads.limitChoices(now: Date()).filter { $0.closeFailure != nil }
        ForEach(failed) { choice in
            if let failure = choice.closeFailure {
                CloseFailureLine(chat: choice.chat, label: choice.label, failure: failure)
            }
        }
    }

    /// The pick, while that thread is still open.
    private var pickedChoice: Int? {
        guard let pick, model.threads.open.contains(where: { $0.chat == pick }) else { return nil }
        return pick
    }

    private var confirmQuestion: String {
        ThreadsPresentation.closeQuestion(label: pick.flatMap { model.thread(of: $0)?.label } ?? "This thread")
    }

    /// A working pick asks first, as Close thread does.
    private func closeAndStart() {
        guard let chat = pickedChoice else { return }
        if model.isBusy(chat: chat) {
            confirming = true
        } else {
            start(closing: chat)
        }
    }

    private func start(closing: Int?) {
        model.startThread(proposal, closing: closing)
    }
}

/// A thread calling you while you are in Main (AM1): amber, "Thread 2 has
/// a question", its first line, Go to Thread 2 ⌃2 and Later. Drawn by the
/// app; never part of Main's transcript.
struct CallingCardView: View {
    let card: CallingCard
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(Theme.iconFont(12))
                    .foregroundStyle(Theme.wait)
                    .accessibilityHidden(true)
                Text(card.title)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "hourglass")
                        .font(Theme.iconFont(10))
                        .accessibilityHidden(true)
                    Text("Waiting for you")
                        .scaledFont(11, weight: .medium)
                }
                .foregroundStyle(Theme.wait)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.waitSoft, in: Capsule())
            }
            Text(card.line)
                .scaledFont(13)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                Button(card.goLabel) { model.switchToConversation(slot: card.slot) }
                    .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    .accessibilityLabel(model.thread(of: card.thread).map {
                        ThreadsPresentation.spokenGoLabel(label: $0.label)
                    } ?? card.goLabel)
                Button("Later") { model.dismissCalling(card) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.wait, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Why a thread's close was refused, and "Close without logging" when its
/// log step could not start: on the thread's card, its row in Main, and
/// the limit card (v0.16, carry 2).
struct CloseFailureLine: View {
    let chat: Int
    /// "Thread 1": named when the line is not on the thread's own card.
    var label: String? = nil
    let failure: CloseFailure
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.map { "\($0): \(failure.message)" } ?? failure.message)
                .scaledFont(11)
                .foregroundStyle(Theme.deny)
                .fixedSize(horizontal: false, vertical: true)
            if failure.offersCloseWithoutLogging {
                Button("Close without logging") { model.closeThreadWithoutLogging(chat: chat) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .disabled(model.closingThreads[chat] != nil || model.connection != .connected)
                    .accessibilityLabel(label.map { "Close \($0) without logging" } ?? "Close without logging")
            }
        }
    }
}
