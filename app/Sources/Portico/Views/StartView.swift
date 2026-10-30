import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The start screen, frame "V4 · First launch" in design/portico.pen
/// (A4 before it): shown when no chat is selected. A greeting, one large
/// composer with `+`, the permission mode chip and Send, the deployment's
/// actions as suggestion chips, and a quiet line saying where the agent
/// works — the folder is chosen once (at setup, or the deployment's
/// default) and changed in Settings, not here. Enter (or Send) starts the
/// session in that folder and sends the message in one motion.
///
/// With a live session at launch (v0.6, frame "Y1 · Launch with a live
/// session") the same screen continues it instead: the composer and the
/// suggestions send to that session and show its conversation, and the
/// quiet line says which session, with View and Start a new session.
///
/// v0.11 (item 66): the composer has the conversation's slash list, from
/// the commands the gateway kept for the folder, before any engine runs.
struct StartView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dictation: Dictation
    @FocusState private var focused: Bool
    @State private var slash = SlashListState()

    /// The slash list for what is typed, when it is open (v0.11 item 66).
    private var slashCompletion: SlashCompletion? {
        guard connected else { return nil }
        return slash.completion(text: model.startDraft, agentCommands: model.startAgentCommands)
    }

    private var connected: Bool { model.connection == .connected }
    /// The live session this welcome continues, if it does.
    private var continuing: ChatSummary? { model.continuingSession.flatMap { model.summary(of: $0) } }
    private var canSend: Bool {
        guard connected, !model.startDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let live = continuing?.chat { return !model.isSessionCommandPending(chat: live) }
        return model.startFolder != nil && !model.isStarting
    }
    /// A suggestion can go now: to the continued session when it is free,
    /// else to a new session in the start folder.
    private var canSuggest: Bool {
        guard connected else { return false }
        if let live = continuing?.chat {
            return !model.isBusy(chat: live) && !model.isSending(chat: live) && !model.isSessionCommandPending(chat: live)
        }
        return model.startFolder != nil && !model.isStarting
    }

    var body: some View {
        VStack(spacing: 28) {
            greeting
            VStack(alignment: .leading, spacing: 8) {
                composer
                if let error = model.startError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }
            if let actions = model.hello?.actions, !actions.isEmpty {
                suggestions(actions)
            }
            if let live = continuing {
                continuingLine(live)
            } else {
                folderLine
            }
        }
        // v0.11 (58): the conversation's reading column.
        .frame(maxWidth: ConversationColumn.maxWidth)
        .padding(EdgeInsets(top: 32, leading: 48, bottom: 120, trailing: 48))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    // MARK: greeting

    /// The mark beside the greeting: the deployment's brand icon when it
    /// gives one that can be read (`hello.brand.icon`, as the Dock, About
    /// panel and sidebar header load it), else a sparkle on the accent.
    enum GreetingMark: Equatable {
        case icon(BrandIconImage)
        case sparkle

        init(brand: BrandPresentation) {
            if let icon = brand.icon { self = .icon(icon) } else { self = .sparkle }
        }
    }

    /// The mark's side, in points: about 1.6 times the v0.3 mark (34), so
    /// it holds its own beside the 40-point greeting.
    static let markSize: CGFloat = 54
    /// The sparkle inside the accent tile.
    static let sparkleSize: CGFloat = 26

    @ViewBuilder
    private var greetingMark: some View {
        switch GreetingMark(brand: model.brand) {
        case .icon(let icon):
            // Rounded when the icon is a flat square (v0.7 decision 5).
            BrandIcon(icon: icon, side: Self.markSize)
                .accessibilityLabel(model.brand.name)
        case .sparkle:
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(model.brand.accent ?? Theme.accent)
                Image(systemName: "sparkle")
                    .font(.system(size: Self.sparkleSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.markSize, height: Self.markSize)
            .accessibilityHidden(true)
        }
    }

    private var greeting: some View {
        HStack(spacing: 16) {
            greetingMark
            Text(Self.greeting())
                .font(.system(size: 40, design: .serif))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    /// "Good morning, Larry": the part of the day and the first word of the
    /// account's full name; no name, no comma.
    static func greeting(at date: Date = Date(), fullName: String = NSFullUserName()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        guard let first = PersonName(fullName: fullName).first else { return part }
        return "\(part), \(first)"
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.startAttachments.isEmpty {
                chips
            }
            ZStack(alignment: .topLeading) {
                if model.startDraft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.startDraft)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(minHeight: 44, maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if slashCompletion != nil,
                            let key = SlashCompletion.Key(press.key, modifiers: press.modifiers, composing: InputBar.isComposing())
                        {
                            return slashKey(key)
                        }
                        return InputBar.handleReturn(modifiers: press.modifiers, composing: InputBar.isComposing(), send: send)
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
                        guard let key = SlashCompletion.Key(press.key, modifiers: press.modifiers, composing: InputBar.isComposing()) else {
                            return .ignored
                        }
                        return slashKey(key)
                    }
            }
            HStack(spacing: 8) {
                Button(action: pickAttachments) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help(continuing == nil ? "Attach files to the first message" : "Attach files to the message")
                if let live = continuing {
                    // The continued session's own mode, changed on it.
                    if let mode = model.mode(of: live.chat) {
                        ModeChip(
                            mode: mode, agentName: model.hello?.brand.agentName ?? model.brand.name,
                            enabled: connected
                        ) { model.setMode($0, for: live.chat) }
                    }
                } else {
                    ModeChip(
                        mode: model.startModeShown, agentName: model.hello?.brand.agentName ?? model.brand.name,
                        enabled: connected && !model.isStarting
                    ) { model.startMode = $0 }
                }
                Spacer(minLength: 0)
                if let line = DictationLine.text(dictation, composer: voiceComposer.id) {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                MicButton(composer: voiceComposer, side: 30, bordered: true)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(model.brand.accent ?? Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .opacity(canSend ? 1 : 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .keyboardShortcut(.return, modifiers: .command)
                .help(sendHelp)
                .disabled(!canSend)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 12, trailing: 16))
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }.map(\.path)
            guard !files.isEmpty else { return false }
            model.attachToStart(files)
            return true
        }
        .slashList {
            if let completion = slashCompletion {
                SlashCommandList(
                    completion: completion, selection: slash.selection,
                    agentName: model.hello?.brand.agentName ?? model.brand.name
                ) { item in
                    pickSlash(item, send: item.group == .portico)
                }
            }
        }
        .onChange(of: SlashCompletion.query(in: model.startDraft)) { _, query in slash.queryChanged(to: query) }
    }

    /// A key while the slash list is open (v0.11 item 66); ignored when it is closed.
    private func slashKey(_ key: SlashCompletion.Key) -> KeyPress.Result {
        guard let completion = slashCompletion else { return .ignored }
        if let picked = slash.apply(completion.handle(key, selection: slash.selection)) {
            pickSlash(picked.item, send: picked.send)
        }
        return .handled
    }

    /// Put the picked command in the composer; send it when it is one of
    /// Portico's own picked with Enter, as the conversation's composer does.
    private func pickSlash(_ item: SlashCompletion.Item, send andSend: Bool) {
        model.startDraft = item.completion
        focused = true
        if andSend { send() }
    }

    private var placeholder: String {
        if !connected { return "Not connected" }
        if let live = continuing {
            // As the conversation's input bar says while a log or renewal is out.
            if model.isRenewing(chat: live.chat) { return "Starting the next session…" }
            if model.isLogging(chat: live.chat) { return "Logging the session…" }
            return "Continue Session \(live.chat) — what next?"
        }
        if model.isStarting { return "Starting…" }
        return "What should we work on? Ask anything, or drop a file here"
    }

    private var sendHelp: String {
        if let live = continuing { return "Send to Session \(live.chat) (Enter)" }
        return model.startFolder == nil ? "Choose a folder in Settings first" : "Start and send (Enter)"
    }

    /// Y1's quiet line in place of the folder line: which session the
    /// composer continues, when it started and last answered, then View
    /// (its conversation, nothing sent) and Start a new session (New,
    /// which asks to log first when there is unlogged work) as two small
    /// bordered buttons the size of the suggestion chips (v0.7 decision 2,
    /// AA1), so they read as clickable.
    private func continuingLine(_ live: ChatSummary) -> some View {
        // The words on one line, the two buttons under them (AA1): side by
        // side they crowd the 720-point column and the words truncate.
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                // Re-read each minute so "last reply … ago" moves.
                TimelineView(.everyMinute) { context in
                    Text(SessionPresentation(summary: live).continuingLine(now: context.date))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                SmallBorderedButton(title: "View Session \(live.chat)") { model.open(chat: live.chat) }
                    .help("Show Session \(live.chat)'s conversation")
                if model.canRenew(chat: live.chat) {
                    SmallBorderedButton(title: "Start a new session") { model.requestNew(chat: live.chat) }
                        .disabled(!connected || model.isSessionCommandPending(chat: live.chat))
                        .help("End Session \(live.chat) and start the next")
                }
            }
        }
    }

    /// V4's quiet line: where the agent works, and that Settings changes it.
    private var folderLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(model.workingFolderLine)
                .font(.system(size: 12))
        }
        .foregroundStyle(Theme.text3)
        .help(model.startFolder?.path ?? "Settings › General › Folder")
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.startAttachments, id: \.self) { path in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        Button { model.detachFromStart(path) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.hover)
                        .foregroundStyle(Theme.text3)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: Capsule())
                    .help(path)
                }
            }
        }
    }

    // MARK: suggestions

    private func suggestions(_ actions: [Action]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.prefix(4).enumerated()), id: \.offset) { _, action in
                Button {
                    if let live = continuing?.chat {
                        model.continueSession(chat: live, action: action.text)
                    } else {
                        model.startChat(text: action.text, fromComposer: false)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text2)
                        Text(action.label)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Theme.control, in: Capsule())
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .help(action.text)
                .disabled(!canSuggest)
            }
        }
    }

    // MARK: actions

    private func send() {
        guard canSend else { return }
        // A talk into this composer ends first: what is shown is what goes.
        dictation.willSend(from: voiceComposer.id)
        if let live = continuing?.chat {
            model.continueSession(chat: live, text: model.startDraft)
        } else {
            model.startChat(text: model.startDraft)
        }
    }

    /// The welcome's composer for Talk (v0.9 decision 1). Its send is
    /// Send's, read from the model when the talk stops.
    private var voiceComposer: Dictation.Composer {
        Dictation.Composer(
            id: "start",
            text: { [model] in model.startDraft },
            setText: { [model] in model.startDraft = $0 },
            send: { [model] in StartView.sendSpoken(model) })
    }

    /// Send, from outside the view: to the continued session, or a new one
    /// in the start folder, when that could be sent now.
    static func sendSpoken(_ model: AppModel) {
        let text = model.startDraft
        guard model.connection == .connected, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let live = model.continuingSession.flatMap({ model.summary(of: $0) })?.chat {
            guard !model.isSessionCommandPending(chat: live) else { return }
            model.continueSession(chat: live, text: text)
        } else {
            guard model.startFolder != nil, !model.isStarting else { return }
            model.startChat(text: text)
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        model.attachToStart(panel.urls.map(\.path))
    }
}

/// A small bordered capsule button, drawn as the welcome's suggestion chips
/// are (13-point text, 6 × 12 padding, the control fill and a hairline
/// border) with their hover tint and pointing-hand cursor: View Session N
/// and Start a new session under the composer (v0.7 decision 2, AA1).
struct SmallBorderedButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Theme.control, in: Capsule())
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.hoverCapsule)
        .fixedSize()
        .accessibilityLabel(title)
    }
}
