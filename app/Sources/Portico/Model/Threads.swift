import Foundation

// MARK: - Threads (v0.16)

/// Main and its open threads, read from `chats` (a thread is a chat with
/// `thread` set). Pure, so the sidebar's rows, the keys and the proposal
/// card are tested without a window.
struct ThreadsPresentation: Equatable {
    let chats: [ChatSummary]
    /// The conversation on screen: its row in the list opens into the card.
    let current: Int?
    /// How many threads may be open beside Main.
    let limit: Int
    /// Chats with a card open (a question or a permission): Needs you even
    /// before the gateway's state word says so.
    let waiting: Set<Int>
    /// Threads whose last close was refused, with why (`closeFailures`).
    let closeFailures: [Int: CloseFailure]
    /// Threads whose turn ended while you were elsewhere, not opened
    /// since (§9.3): their rows say New reply.
    let newReplies: Set<Int>

    init(
        chats: [ChatSummary], current: Int?, limit: Int = 2, waiting: Set<Int> = [],
        closeFailures: [Int: CloseFailure] = [:], newReplies: Set<Int> = []
    ) {
        self.chats = chats
        self.current = current
        self.limit = limit
        self.waiting = waiting
        self.closeFailures = closeFailures
        self.newReplies = newReplies
    }

    /// Main: the newest chat that has not ended and is not a thread.
    var main: ChatSummary? { ChatSummary.main(in: chats) }

    /// The open threads, by slot.
    var open: [ChatSummary] {
        chats.filter { $0.ended == nil && $0.thread != nil }
            .sorted { ($0.thread?.slot ?? 0, $0.chat) < ($1.thread?.slot ?? 0, $1.chat) }
    }

    /// The slot a thread started now would take: the lowest free one.
    var freeSlot: Int? {
        guard limit > 0 else { return nil }
        let taken = Set(open.compactMap { $0.thread?.slot })
        return (1...limit).first { !taken.contains($0) }
    }

    /// Every slot is taken: a proposal asks to close one first.
    var atLimit: Bool { open.count >= limit }

    /// The thread on screen, when the conversation on screen is one.
    var currentThread: ThreadInfo? {
        chats.first { $0.chat == current }?.thread
    }

    /// The sidebar's list (§9.6): Main, then Thread 1, Thread 2, always in
    /// that order, so nothing moves when you switch. The conversation in
    /// `current` is the open row, drawn as its card.
    func rows(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [ThreadRowPresentation] {
        var rows: [ThreadRowPresentation] = []
        if let main {
            var shown = row(main, label: "Main", slot: 0, now: now)
            shown.subtitle = Self.mainSubtitle(main, open: shown.isOpen, calendar: calendar, locale: locale)
            rows.append(shown)
        }
        for thread in open {
            guard let info = thread.thread else { continue }
            rows.append(row(thread, label: info.label, slot: info.slot, now: now))
        }
        return rows
    }

    /// Main's subtitle: "Session 4 · Mobile login screen" in a closed row,
    /// "Session 4 · started 1:30 PM" when it is the open card (§9.6); the
    /// number alone when there is nothing to add.
    static func mainSubtitle(_ main: ChatSummary, open: Bool, calendar: Calendar, locale: Locale) -> String {
        let shown = SessionPresentation(summary: main)
        let detail: String?
        if open {
            detail = SessionTime.parse(main.created).map { "started \(SessionTime.clock($0, calendar: calendar, locale: locale))" }
        } else {
            detail = shown.title
        }
        return [shown.number, detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// At the limit, the threads to pick from (AM4): label, then the title
    /// and last activity, "Pricing page · last reply 20 min ago".
    func limitChoices(now: Date) -> [LimitChoice] {
        open.compactMap { summary in
            guard let info = summary.thread else { return nil }
            let row = row(summary, label: info.label, slot: info.slot, now: now)
            let activity: String?
            switch row.status {
            case .working: activity = "working now"
            case .needsYou: activity = "needs you"
            case .newReply: activity = "new reply"
            case .lastReply(let ago): activity = "last reply \(ago)"
            case .none: activity = nil
            }
            let line = [row.title, activity].compactMap { $0 }.joined(separator: " · ")
            return LimitChoice(chat: summary.chat, label: info.label, line: line, closeFailure: closeFailures[summary.chat])
        }
    }

    /// The Go button's label: "Go to Thread 2". Buttons, cards and rows
    /// carry no key glyph (§9.2); the tooltip spells the key.
    static func goLabel(label: String) -> String { "Go to \(label)" }

    /// A conversation's key spelled out for a tooltip: "Control-0" for
    /// Main, "Control-1", "Control-2" for the threads (§9.2).
    static func keyName(slot: Int) -> String { "Control-\(slot)" }

    /// The confirm before closing a thread mid-turn.
    static func closeQuestion(label: String) -> String {
        "\(label) is still working. Close it anyway?"
    }

    private func row(_ summary: ChatSummary, label: String, slot: Int, now: Date) -> ThreadRowPresentation {
        let status: ThreadRowPresentation.Status
        if summary.state == .waitingOnYou || waiting.contains(summary.chat) {
            status = .needsYou
        } else if summary.state == .working {
            status = .working
        } else if newReplies.contains(summary.chat) {
            status = .newReply
        } else if let reply = SessionTime.parse(summary.lastReply) {
            status = .lastReply(SessionTime.ago(reply, now: now))
        } else {
            status = .none
        }
        let title = SessionPresentation(summary: summary).title
        return ThreadRowPresentation(
            chat: summary.chat, label: label, title: title, status: status, keyName: Self.keyName(slot: slot),
            closeFailure: closeFailures[summary.chat], slot: slot, isOpen: summary.chat == current, subtitle: title)
    }
}

/// Why a thread's close was refused: the gateway's code and message.
struct CloseFailure: Equatable {
    /// The codes of a log step that could not start (its turn's engine
    /// could not start, or refused the message; Ruling 8).
    /// The preflight refusing the log step's engine reaches the app as
    /// `lifecycle.before_first_chat_failed`, as on `chat.new`.
    static let logStepCannotStart: Set<String> = [
        "engine.start_failed", "engine.send_failed", "lifecycle.before_first_chat_failed",
    ]

    let code: String
    let message: String

    /// "Close without logging" is the way out only when the log step could
    /// not start; `chat.busy` or `thread.not_open` are not helped by it.
    var offersCloseWithoutLogging: Bool { Self.logStepCannotStart.contains(code) }
}

/// One thread the limit card offers to close (AM4).
struct LimitChoice: Equatable, Identifiable {
    let chat: Int
    /// "Thread 1".
    let label: String
    /// "Pricing page · last reply 20 min ago".
    let line: String
    /// Its last close was refused (a Close and start's close included).
    var closeFailure: CloseFailure? = nil

    var id: Int { chat }
}

/// The View menu's conversations (§2.4): "Main" Control-0 and each open thread
/// with its slot's key, only with threads on.
struct ThreadMenuItem: Equatable, Identifiable {
    let title: String
    let slot: Int

    /// The digit the menu binds with Control.
    var key: String { "\(slot)" }
    var id: Int { slot }

    static func items(threads: ThreadsPresentation, threadsOn: Bool) -> [ThreadMenuItem] {
        guard threadsOn else { return [] }
        return [ThreadMenuItem(title: "Main", slot: 0)]
            + threads.open.compactMap { $0.thread.map { ThreadMenuItem(title: $0.label, slot: $0.slot) } }
    }
}

/// One conversation in the sidebar's list (AM1; §9.6, AP4/AP5).
struct ThreadRowPresentation: Equatable, Identifiable {
    enum Status: Equatable {
        case working
        case needsYou
        /// The turn ended while you were elsewhere and the thread has not
        /// been opened since: an accent dot and "New reply" (§9.3).
        case newReply
        /// The last reply's age, "5 min ago".
        case lastReply(String)
        case none
    }

    let chat: Int
    /// "Main", "Thread 1".
    let label: String
    let title: String?
    let status: Status
    /// The key spelled out, for the tooltip only: "Control-0".
    let keyName: String
    /// The thread's last close was refused: the row says why.
    var closeFailure: CloseFailure? = nil
    /// 0 for Main, 1 and 2 for the threads: the slot a click switches to.
    var slot: Int = 0
    /// The conversation you're in: this row is drawn as the open card.
    var isOpen: Bool = false
    /// The line under the name: Main's "Session 4 · …", a thread's title.
    var subtitle: String? = nil

    var id: Int { chat }

    /// A thread's row (the branch icon, Close thread in its menu), not Main's.
    var isThread: Bool { slot > 0 }

    /// The row's tooltip: "Go to Thread 2 (Control-2)".
    var help: String { "Go to \(label) (\(keyName))" }

    /// What VoiceOver reads, without the key glyph: "Thread 2, needs you".
    var spokenLabel: String {
        switch status {
        case .working: "\(label), working"
        case .needsYou: "\(label), needs you"
        case .newReply: "\(label), new reply"
        case .lastReply(let ago): "\(label), last reply \(ago)"
        case .none: label
        }
    }
}

/// The proposal card drawn in place of Main's `open_thread` row (AM2, AM4),
/// and the record it leaves.
struct ProposalPresentation: Equatable {
    enum Kind: Equatable {
        /// Start thread / Not now.
        case offer
        /// Both slots taken: pick one to close (Close and start / Not now).
        case atLimit
        case started
        case notStarted
    }

    let kind: Kind
    /// "Start Thread 1", "Close a thread to start another", or the record.
    let title: String
    let brief: String
    /// "It takes this brief and pricing.html, not this conversation." (Ruling 13)
    let takesLine: String
    /// "Thread 1 started" / "Not started"; `nil` while it is still an offer.
    let record: String?
    /// "Go to Thread 1" on a started record while that thread is open.
    let goLabel: String?
    /// Its tooltip, the key spelled out: "Control-1".
    let goHelp: String?
    /// The slot Go switches to.
    let goSlot: Int?

    init(proposal: ThreadProposal, threads: ThreadsPresentation) {
        brief = proposal.brief
        takesLine = Self.takesLine(files: proposal.files)
        switch proposal.state {
        case .pending:
            if threads.atLimit {
                kind = .atLimit
                title = "Close a thread to start another"
            } else {
                kind = .offer
                title = "Start Thread \(threads.freeSlot ?? 1)"
            }
            record = nil
            goLabel = nil
            goHelp = nil
            goSlot = nil
        case .started:
            let info = threads.chats.first { $0.chat == proposal.thread }?.thread
            let started = "\(info?.label ?? "Thread") started"
            kind = .started
            title = started
            record = started
            let stillOpen = threads.open.contains { $0.chat == proposal.thread }
            if stillOpen, let info {
                goLabel = ThreadsPresentation.goLabel(label: info.label)
                goHelp = ThreadsPresentation.keyName(slot: info.slot)
                goSlot = info.slot
            } else {
                goLabel = nil
                goHelp = nil
                goSlot = nil
            }
        case .dismissed:
            kind = .notStarted
            title = "Not started"
            record = "Not started"
            goLabel = nil
            goHelp = nil
            goSlot = nil
        }
    }

    /// What the thread takes along: the brief and the files, by name.
    static func takesLine(files: [String]) -> String {
        let names = files.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard let last = names.last else { return "It takes this brief, not this conversation." }
        let phrase = names.count == 1 ? last : "\(names.dropLast().joined(separator: ", ")) and \(last)"
        return "It takes this brief and \(phrase), not this conversation."
    }
}

/// A thread calling you while you are in Main (AM1): drawn by the app from
/// the thread's open card, never a gateway frame, so it can never reach
/// Main's agent (Review Focus 4).
struct CallingCard: Equatable, Identifiable {
    /// The thread's chat.
    let thread: Int
    let slot: Int
    let cardId: String
    /// "Thread 2 has a question" (for a permission too, Ruling 14).
    let title: String
    /// The first line of the first question, or the permission's summary.
    let line: String
    /// "Go to Thread 2".
    let goLabel: String
    /// Its tooltip, the key spelled out: "Control-2".
    let goHelp: String

    var id: String { "\(thread):\(cardId)" }
}

/// A thread finishing while you are elsewhere (§9.3): "Thread 1 is done",
/// the first line of its last reply, Go to Thread 1 and Dismiss. Drawn by
/// the app in Main, like the calling card: never a gateway frame, never
/// in Main's transcript or its agent's context. In memory only, so turns
/// that ended before a restart never show one.
struct DoneCard: Equatable, Identifiable {
    /// The thread's chat.
    let thread: Int
    let slot: Int
    /// "Thread 1 is done".
    let title: String
    /// The first line of the thread's last reply; `nil` when its last turn
    /// said nothing.
    let line: String?
    /// "Go to Thread 1".
    let goLabel: String
    /// Its tooltip, the key spelled out: "Control-1".
    let goHelp: String

    var id: String { "done:\(thread)" }

    /// Main's done cards: one per open thread with a new reply whose card
    /// was not dismissed. A thread with a card open (a question or a
    /// permission) shows its calling card instead.
    static func cards(
        threads: ThreadsPresentation, dismissed: Set<Int>, transcripts: [Int: [TranscriptItem]]
    ) -> [DoneCard] {
        threads.open.compactMap { summary in
            guard let info = summary.thread, threads.newReplies.contains(summary.chat),
                !dismissed.contains(summary.chat), !threads.waiting.contains(summary.chat)
            else { return nil }
            return DoneCard(
                thread: summary.chat, slot: info.slot, title: "\(info.label) is done",
                line: replyLine(in: transcripts[summary.chat] ?? []),
                goLabel: ThreadsPresentation.goLabel(label: info.label), goHelp: ThreadsPresentation.keyName(slot: info.slot))
        }
    }

    /// The first non-empty line of the last turn's last reply, trimmed:
    /// only text after the person's last message counts, so a turn that
    /// said nothing never borrows an older reply.
    static func replyLine(in items: [TranscriptItem]) -> String? {
        let start = items.lastIndex { if case .userText = $0 { true } else { false } }.map { $0 + 1 } ?? 0
        for item in items[start...].reversed() {
            guard case .assistantText(_, let text) = item else { continue }
            if let line = text.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
            {
                return line
            }
        }
        return nil
    }
}

extension AppModel {
    /// Threads show in single presentation with a gateway that lists `threads.v1`.
    var threadsOn: Bool { offers(ThreadProposal.capability) && isSinglePresentation }

    /// The chat's thread record; `nil` for Main and every other chat.
    func thread(of chat: Int) -> ThreadInfo? { summary(of: chat)?.thread }

    /// Main and the threads as the window shows them now.
    var threads: ThreadsPresentation {
        ThreadsPresentation(
            chats: chats, current: shownChat, limit: hello?.threadsMax ?? 2,
            waiting: Set(openCards.filter { !$0.value.isEmpty }.keys), closeFailures: closeFailures,
            newReplies: newThreadReplies)
    }

    /// The sidebar's open card (§9.6): the open thread on screen, else Main
    /// (an earlier session or the document view keeps Main's row open).
    var sidebarCard: ChatSummary? {
        if threadsOn, let shown = shownChat, let summary = summary(of: shown), summary.thread != nil, summary.ended == nil {
            return summary
        }
        return liveSession
    }

    /// Main and the threads as the sidebar's list draws them: the card's
    /// chat is the open row (§9.6).
    var sidebarThreads: ThreadsPresentation {
        let now = threads
        return ThreadsPresentation(
            chats: now.chats, current: sidebarCard?.chat, limit: now.limit, waiting: now.waiting,
            closeFailures: now.closeFailures, newReplies: now.newReplies)
    }

    /// The thread on screen ended (closed here or elsewhere): the window
    /// goes back to Main. An ended thread opened from History stays.
    func returnToMainIfShownThreadEnded(wasLiveThread: Bool) {
        guard wasLiveThread, let shown = selected, isEnded(chat: shown), let main = liveSession?.chat else { return }
        open(chat: main)
    }

    /// Control-0 Main, Control-1 Thread 1, Control-2 Thread 2: that conversation, out of the
    /// document view if it had the window. An empty slot does nothing.
    func switchToConversation(slot: Int) {
        let target: Int?
        if slot == 0 {
            target = liveSession?.chat
        } else {
            target = threadsOn ? threads.open.first { $0.thread?.slot == slot }?.chat : nil
        }
        guard let target else { return }
        closeDocumentView()
        open(chat: target)
    }

    /// The proposal drawn in place of an `open_thread` tool row.
    func proposal(forToolUse id: String) -> ThreadProposal? {
        proposals.values.first { $0.toolUseId == id }
    }

    func proposalPresentation(for proposal: ThreadProposal) -> ProposalPresentation {
        ProposalPresentation(proposal: proposal, threads: threads)
    }

    /// Not now is out for this proposal: its card waits for the answer.
    var dismissingProposals: Set<String> { Set(dismissing.keys) }

    /// The thread is being closed: its own `thread.close` is out, or a
    /// Close and start is closing it. Close thread waits either way (the
    /// gateway would refuse a second close as `thread.not_open`).
    func isClosing(chat: Int) -> Bool {
        closingThreads[chat] != nil || startingClose == chat
    }

    /// Close thread: a thread mid-turn asks "Thread N is still working.
    /// Close it anyway?" first (`closingThread`); otherwise it closes now.
    func requestCloseThread(chat: Int) {
        guard thread(of: chat) != nil, !isEnded(chat: chat), !isClosing(chat: chat) else { return }
        if isBusy(chat: chat) {
            closingThread = chat
        } else {
            closeThread(chat: chat, log: true)
        }
    }

    /// The confirm's Close.
    func confirmCloseThread() {
        guard let chat = closingThread else { return }
        closingThread = nil
        closeThread(chat: chat, log: true)
    }

    /// "Close without logging": the way out when a close failed because
    /// its log step could not start (`closeFailures`).
    func closeThreadWithoutLogging(chat: Int) {
        closeThread(chat: chat, log: false)
    }

    /// The calling cards Main shows: one per open thread with a card open
    /// that was not put off with Later. Only in Main (Ruling 20).
    func callingCards(in chat: Int) -> [CallingCard] {
        guard threadsOn, chat == liveSession?.chat else { return [] }
        return threads.open.compactMap { summary in
            guard let info = summary.thread else { return nil }
            let hidden = dismissedCalls[summary.chat] ?? []
            guard let card = (openCards[summary.chat] ?? []).first(where: { !hidden.contains($0.id) }) else { return nil }
            return CallingCard(
                thread: summary.chat, slot: info.slot, cardId: card.id, title: "\(info.label) has a question",
                line: Self.callingLine(card), goLabel: ThreadsPresentation.goLabel(label: info.label),
                goHelp: ThreadsPresentation.keyName(slot: info.slot))
        }
    }

    /// Main's done cards (§9.3): only in Main, with threads on.
    func doneCards(in chat: Int) -> [DoneCard] {
        guard threadsOn, chat == liveSession?.chat else { return [] }
        return DoneCard.cards(threads: threads, dismissed: dismissedDone, transcripts: transcripts)
    }

    /// A live turn ended in `chat`: a thread you are not in gets its New
    /// reply dot and Main's done card (again, if an earlier one was
    /// dismissed). Main, other chats and the thread on screen get nothing.
    func noteThreadTurnFinished(chat: Int) {
        guard threadsOn, let summary = summary(of: chat), summary.thread != nil, summary.ended == nil,
            shownChat != chat
        else { return }
        newThreadReplies.insert(chat)
        dismissedDone.remove(chat)
    }

    /// The thread was opened: its dot and its done card go.
    func noteThreadSeen(chat: Int) {
        if newThreadReplies.contains(chat) { newThreadReplies.remove(chat) }
        if dismissedDone.contains(chat) { dismissedDone.remove(chat) }
    }

    /// Dismiss on a done card: the card goes; the row keeps New reply.
    func dismissDone(_ card: DoneCard) {
        dismissedDone.insert(card.thread)
    }

    /// A question card's first question, first line; a permission's summary.
    static func callingLine(_ card: CardAsk) -> String {
        if let permission = card.permission { return permission.summary }
        let text = card.questions?.first?.question ?? card.title
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? card.title
    }

    /// Every live thread the chat list names is loaded (not shown), so its
    /// state and cards are current without opening it (Ruling 20).
    func loadLiveThreads() {
        guard threadsOn else { return }
        for summary in chats where summary.thread != nil && summary.ended == nil {
            if !openedChats.contains(summary.chat) && !isLoading(chat: summary.chat) { load(chat: summary.chat) }
        }
    }
}
