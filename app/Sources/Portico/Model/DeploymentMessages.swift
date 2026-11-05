import Foundation

/// v0.22 (S3): the deployment's messages waiting above the open chat's
/// message box. A message that arrives while a reply streams in the open
/// chat is held; once nothing streams it docks, and stays docked through
/// the next reply. Dismissed is gone. Window-wide, not per chat, never
/// sent to the agent and never saved (spec §4).
struct DeploymentMessageQueue: Equatable {
    /// At most this many cards show; the rest are "N more".
    static let shownMax = 3

    /// How many ids this run remembers, so a dismissed one sent again does not dock again.
    static let seenMax = 200

    private(set) var docked: [DeploymentMessage] = []
    private(set) var held: [DeploymentMessage] = []
    /// The ids taken this run, oldest first, at most `seenMax`.
    private var seenOrder: [String] = []
    private var seen: Set<String> = []

    var isEmpty: Bool { docked.isEmpty && held.isEmpty }

    /// Take a new message; whether it was taken. An `id` already taken this
    /// run (docked, held or dismissed) is not taken again.
    @discardableResult
    mutating func receive(_ message: DeploymentMessage, streaming: Bool) -> Bool {
        guard !seen.contains(message.id), self.message(message.id) == nil else { return false }
        seen.insert(message.id)
        seenOrder.append(message.id)
        if seenOrder.count > Self.seenMax {
            seen.remove(seenOrder.removeFirst())
        }
        if streaming {
            held.append(message)
        } else {
            release()
            docked.append(message)
        }
        return true
    }

    /// Nothing streams now: the held messages dock, in the order they came.
    mutating func release() {
        guard !held.isEmpty else { return }
        docked += held
        held = []
    }

    mutating func dismiss(_ id: String) {
        docked.removeAll { $0.id == id }
        held.removeAll { $0.id == id }
    }

    func message(_ id: String) -> DeploymentMessage? {
        docked.first { $0.id == id } ?? held.first { $0.id == id }
    }

    /// The cards to draw, oldest first (newest at the bottom), and how many
    /// older ones are beyond them.
    func visible(streaming: Bool) -> (shown: [DeploymentMessage], more: Int) {
        let all = streaming ? docked : docked + held
        let shown = Array(all.suffix(Self.shownMax))
        return (shown, all.count - shown.count)
    }
}

enum DeploymentMessagePresentation {
    /// The line above the cards when more wait: "2 more".
    static func moreText(_ more: Int) -> String? {
        more > 0 ? "\(more) more" : nil
    }
}
