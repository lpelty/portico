import Foundation

// MARK: - Threads (v0.16)

/// Main and its open threads, read from `chats` (a thread is a chat with
/// `thread` set). Pure, so the sidebar's rows, the keys and the proposal
/// card are tested without a window.
struct ThreadsPresentation: Equatable {
    let chats: [ChatSummary]
    /// The conversation on screen: its row is the card, not a row.
    let current: Int?
    /// How many threads may be open beside Main.
    let limit: Int
    /// Chats with a card open (a question or a permission): Needs you even
    /// before the gateway's state word says so.
    let waiting: Set<Int>

    init(chats: [ChatSummary], current: Int?, limit: Int = 2, waiting: Set<Int> = []) {
        self.chats = chats
        self.current = current
        self.limit = limit
        self.waiting = waiting
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

    /// The sidebar's rows: every conversation but the one on screen, those
    /// that need you first, else Main, Thread 1, Thread 2.
    func rows(now: Date) -> [ThreadRowPresentation] {
        var rows: [ThreadRowPresentation] = []
        if let main, main.chat != current {
            rows.append(row(main, label: "Main", key: "⌃0", now: now))
        }
        for thread in open where thread.chat != current {
            guard let info = thread.thread else { continue }
            rows.append(row(thread, label: info.label, key: "⌃\(info.slot)", now: now))
        }
        return rows.enumerated()
            .sorted { a, b in
                let (aNeeds, bNeeds) = (a.element.status == .needsYou, b.element.status == .needsYou)
                return aNeeds != bNeeds ? aNeeds : a.offset < b.offset
            }
            .map(\.element)
    }

    private func row(_ summary: ChatSummary, label: String, key: String, now: Date) -> ThreadRowPresentation {
        let status: ThreadRowPresentation.Status
        if summary.state == .waitingOnYou || waiting.contains(summary.chat) {
            status = .needsYou
        } else if summary.state == .working {
            status = .working
        } else if let reply = SessionTime.parse(summary.lastReply) {
            status = .lastReply(SessionTime.ago(reply, now: now))
        } else {
            status = .none
        }
        return ThreadRowPresentation(
            chat: summary.chat, label: label, title: SessionPresentation(summary: summary).title, status: status, key: key)
    }
}

/// Why a thread's close was refused: the gateway's code and message.
struct CloseFailure: Equatable {
    /// The codes of a log step that could not start (its turn's engine
    /// could not start, or refused the message; Ruling 8).
    static let logStepCannotStart: Set<String> = ["engine.start_failed", "engine.send_failed"]

    let code: String
    let message: String

    /// "Close without logging" is the way out only when the log step could
    /// not start; `chat.busy` or `thread.not_open` are not helped by it.
    var offersCloseWithoutLogging: Bool { Self.logStepCannotStart.contains(code) }
}

/// One conversation's row under the sidebar's card (AM1).
struct ThreadRowPresentation: Equatable, Identifiable {
    enum Status: Equatable {
        case working
        case needsYou
        /// The last reply's age, "5 min ago".
        case lastReply(String)
        case none
    }

    let chat: Int
    /// "Main", "Thread 1".
    let label: String
    let title: String?
    let status: Status
    /// "⌃0", "⌃1", "⌃2".
    let key: String

    var id: Int { chat }
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
    /// "Go to Thread 1 ⌃1" on a started record while that thread is open.
    let goLabel: String?
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
            goSlot = nil
        case .started:
            let info = threads.chats.first { $0.chat == proposal.thread }?.thread
            let started = "\(info?.label ?? "Thread") started"
            kind = .started
            title = started
            record = started
            let stillOpen = threads.open.contains { $0.chat == proposal.thread }
            if stillOpen, let info {
                goLabel = "Go to \(info.label) ⌃\(info.slot)"
                goSlot = info.slot
            } else {
                goLabel = nil
                goSlot = nil
            }
        case .dismissed:
            kind = .notStarted
            title = "Not started"
            record = "Not started"
            goLabel = nil
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
    /// "Go to Thread 2 ⌃2".
    let goLabel: String

    var id: String { "\(thread):\(cardId)" }
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
            waiting: Set(openCards.filter { !$0.value.isEmpty }.keys))
    }

    /// ⌃0 Main, ⌃1 Thread 1, ⌃2 Thread 2: that conversation, out of the
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

    /// Close thread: a thread mid-turn asks "Thread N is still working.
    /// Close it anyway?" first (`closingThread`); otherwise it closes now.
    func requestCloseThread(chat: Int) {
        guard thread(of: chat) != nil, !isEnded(chat: chat), closingThreads[chat] == nil else { return }
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
                line: Self.callingLine(card), goLabel: "Go to \(info.label) ⌃\(info.slot)")
        }
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
