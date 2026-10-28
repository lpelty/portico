import Foundation

/// The app's state and the one reducer for gateway messages.
///
/// This file lands with the gateway client (Task 15) carrying only the
/// reconnect policy; the chats, transcripts, cards and artifacts arrive with
/// the model task (Task 16), which extends this class.
@MainActor
final class AppModel: ObservableObject {
    /// The gateway's latest `hello`; `nil` until the first attach.
    @Published private(set) var hello: HelloServer?

    /// The last `seq` seen per chat, the watermark a reconnect asks for events since.
    private(set) var lastSeq: [Int: Int] = [:]

    /// Chats this app has opened in this run; each is re-opened on reattach.
    private(set) var openedChats: Set<Int> = []

    init() {}

    /// Record a `hello` from the gateway and return what to send to catch up.
    ///
    /// Same epoch as last time: the gateway is the one we were talking to, so
    /// re-open every chat with `since` set to its watermark and the ring
    /// buffer fills the gap. A different epoch: the gateway restarted, its
    /// sequence numbers started over, and the ring is empty — drop every
    /// watermark and open from the beginning so the transcript is replayed
    /// exactly once (Review Focus 2).
    func handleHello(_ incoming: HelloServer) -> [ClientMessage] {
        if let previous = hello, previous.epoch != incoming.epoch {
            lastSeq = [:]
        }
        hello = incoming
        return openedChats.sorted().map { chat in
            .chatOpen(ChatOpen(chat: chat, since: lastSeq[chat]))
        }
    }

    /// Remember that a chat has been opened, so a reattach re-opens it.
    func noteOpened(chat: Int) {
        openedChats.insert(chat)
    }

    /// Forget a chat (removed, or no longer shown).
    func noteClosed(chat: Int) {
        openedChats.remove(chat)
        lastSeq[chat] = nil
    }

    /// Advance a chat's watermark from a chat-scoped, sequenced event.
    /// Unsequenced events (a transcript replay) and re-sent frames with an
    /// older `seq` (open cards on `chat.open`) leave it alone.
    func noteSeq(of message: ServerMessage) {
        let envelope = message.envelope
        guard let chat = envelope.chat, let seq = envelope.seq else { return }
        if let seen = lastSeq[chat], seen >= seq { return }
        lastSeq[chat] = seq
    }
}
