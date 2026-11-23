import SwiftUI

/// The sidebar's CONVERSATIONS list (v0.16 §9.6, Pen AP4/AP5): Main,
/// Thread 1, Thread 2 in a fixed order, all on the same left edge and
/// width, so nothing moves when you switch. The row you're in is the open
/// card (`SessionCard`); the others are rows with their label, subtitle
/// and a status (working spinner, amber Needs you, an accent dot and New
/// reply, or the last reply's age). No key glyph: the tooltip spells the
/// key (§9.2). A click switches; a thread's row has Close thread in its
/// context menu.
struct ConversationList: View {
    @EnvironmentObject private var model: AppModel

    /// The rows' and the open card's inner left edge, so the icons line up.
    static let rowInset: CGFloat = 10

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                ForEach(model.sidebarThreads.rows(now: context.date, agentName: model.hello?.brand.agentName)) { row in
                    if row.isOpen, let card = model.sidebarCard, card.chat == row.chat {
                        SessionCard(summary: card)
                            .padding(.vertical, 2)
                    } else {
                        ThreadRow(row: row)
                        // A refused close shows under its row, so Close without
                        // logging is reachable from Main too. The open card
                        // shows it in its footnote.
                        if let failure = row.closeFailure {
                            CloseFailureLine(chat: row.chat, failure: failure)
                                .padding(.horizontal, Self.rowInset)
                                .padding(.bottom, 4)
                        }
                    }
                }
                // v0.28 (PORT-77, ZL1): under the open threads, in words.
                if model.canOpenThread {
                    NewThreadRow()
                }
            }
        }
    }
}

/// "New thread" (v0.28, ZL1 and ZL3): always there, in Main and inside a
/// thread. One click opens an empty thread. With every slot taken it stays
/// clickable and lists the open threads by name, each with Close; closing
/// one opens the new thread.
struct NewThreadRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.textScale) private var textScale

    static let label = "New thread"
    static let help = "Start a new thread · Control-T"
    static let limitSentence = "Two threads are open, which is the most. Close one to start another."

    /// The sentence over the limit list, for the deployment's limit.
    static func limitSentence(limit: Int) -> String {
        limit == 1 ? "A thread is open, which is the most. Close it to start another." : limitSentence
    }

    var body: some View {
        Button { model.newThread() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(Theme.iconFont(13))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(Self.label)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
                if model.openingThread != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("⌃T")
                        .scaledFont(11)
                        .foregroundStyle(Theme.text3)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, ConversationList.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
        .background(model.newThreadLimitShown ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .focusEffectDisabled()
        .disabled(model.connection != .connected)
        .tip(Self.help)
        .accessibilityLabel(Self.label)
        .popover(isPresented: $model.newThreadLimitShown, arrowEdge: .bottom) {
            NewThreadLimitList()
                .environmentObject(model)
                .environment(\.textScale, textScale)
                .popoverSurface()
        }
    }
}

/// The open threads at the limit (ZL3): name, "Thread 1 · working", Close.
struct NewThreadLimitList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text(NewThreadRow.limitSentence(limit: model.threads.limit))
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.threads.limitChoices(now: context.date)) { choice in
                    HStack(spacing: 8) {
                        ConversationIcon(isThread: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.label)
                                .scaledFont(13, weight: .medium)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(choice.line)
                                .scaledFont(11)
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Close") { model.closeForNewThread(chat: choice.chat) }
                            .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                            .disabled(model.isClosing(chat: choice.chat) || model.connection != .connected)
                    }
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// A name as a field (v0.28, ZK2): its text selected, Return saves, Esc
/// cancels, and clicking away leaves the old name.
struct RenameField: View {
    let chat: Int
    let initial: String
    var weight: Font.Weight = .medium
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    static let hint = "Return saves · Esc cancels"

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .scaledFont(13, weight: weight)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(model.brand.accent ?? Theme.accent, lineWidth: 1))
            .focused($focused)
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { model.rename(chat: chat, to: text) }
            .onExitCommand { model.renaming = nil }
            .onChange(of: focused) { _, now in
                if !now, model.renaming == chat { model.renaming = nil }
            }
            .accessibilityLabel("Name")
    }
}

/// Rename…, Name it for me and (a thread) Close thread: the menu on a
/// conversation's row and on its open card (v0.28, ZK2).
struct ConversationNameMenu: View {
    let chat: Int
    let isThread: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("Rename…") { model.renaming = chat }
            .disabled(model.connection != .connected)
        if model.canNameForMe {
            Button("Name it for me") { model.nameForMe(chat: chat) }
                .disabled(model.connection != .connected)
        }
        if isThread {
            Divider()
            Button("Close thread") { model.requestCloseThread(chat: chat) }
                .disabled(model.isClosing(chat: chat) || model.connection != .connected)
        }
    }
}

/// A conversation's name in the list or on the open card. Main with the
/// agent's name (v0.26, ZG2) draws the name and " (Main)" apart, so a long
/// name truncates and "(Main)" stays.
struct ConversationName: View {
    let label: String
    let mainName: String?
    let weight: Font.Weight
    /// Tests: the frames of the whole name and of " (Main)", in global coordinates.
    var onFrames: ((_ whole: CGRect, _ main: CGRect) -> Void)? = nil
    @State private var mainFrame: CGRect = .zero
    @State private var wholeFrame: CGRect = .zero

    var body: some View {
        if let mainName {
            HStack(spacing: 0) {
                Text(mainName).lineLimit(1).truncationMode(.tail)
                Text(" (Main)").fixedSize()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        mainFrame = $0
                        onFrames?(wholeFrame, mainFrame)
                    }
            }
            .scaledFont(13, weight: weight)
            .foregroundStyle(Theme.text)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                wholeFrame = $0
                onFrames?(wholeFrame, mainFrame)
            }
        } else {
            Text(label)
                .scaledFont(13, weight: weight)
                .foregroundStyle(Theme.text)
        }
    }
}

/// Main's speech bubble, a thread's branch (§9.6).
struct ConversationIcon: View {
    let isThread: Bool

    var body: some View {
        Image(systemName: isThread ? "arrow.triangle.branch" : "bubble.left")
            .font(Theme.iconFont(13))
            .foregroundStyle(Theme.text2)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

private struct ThreadRow: View {
    let row: ThreadRowPresentation
    @EnvironmentObject private var model: AppModel

    private var needsYou: Bool { row.status == .needsYou }
    private var renamingHere: Bool { model.renaming == row.chat }

    var body: some View {
        Button { model.switchToConversation(slot: row.slot) } label: {
            HStack(spacing: 8) {
                ConversationIcon(isThread: row.isThread)
                VStack(alignment: .leading, spacing: 1) {
                    // v0.28 (ZK2): a thread's name is a field while it is renamed; Main's
                    // name stays, and its session title (the second line) is the field.
                    if renamingHere, row.isThread {
                        RenameField(chat: row.chat, initial: row.title ?? "")
                        Text(RenameField.hint).scaledFont(11).foregroundStyle(Theme.text2).lineLimit(1)
                    } else {
                        ConversationName(label: row.label, mainName: row.mainName, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if renamingHere {
                            RenameField(chat: row.chat, initial: row.title ?? "", weight: .regular)
                        } else if let subtitle = row.subtitle {
                            Text(subtitle)
                                .scaledFont(11)
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                Spacer(minLength: 0)
                status
            }
            .padding(.vertical, 6)
            .padding(.horizontal, ConversationList.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
        .background(needsYou ? Theme.waitSoft : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .focusEffectDisabled()
        .tip(row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityAddTraits(.isButton)
        // v0.28: a double-click on the row renames it, as Rename… in its menu does.
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.renaming = row.chat })
        .contextMenu { ConversationNameMenu(chat: row.chat, isThread: row.isThread) }
    }

    @ViewBuilder
    private var status: some View {
        switch row.status {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Working")
        case .needsYou:
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(Theme.iconFont(10))
                    .accessibilityHidden(true)
                Text("Needs you")
                    .scaledFont(11, weight: .medium)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Theme.wait)
        case .newReply:
            // §9.3: until the thread is opened.
            HStack(spacing: 5) {
                Circle()
                    .fill(model.brand.accent ?? Theme.accent)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("New reply")
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .lastReply(let ago):
            Text(ago)
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .fixedSize()
        case .none:
            EmptyView()
        }
    }
}
