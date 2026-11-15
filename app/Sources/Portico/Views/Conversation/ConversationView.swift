import SwiftUI

/// One chat's conversation: the transcript (user bubbles, the agent's
/// Markdown, folded tool rows, cards, a note under a stopped or failed
/// turn) scrolled to the newest item, the chat's last status line, and
/// the input bar.
struct ConversationView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel
    /// Where the transcript is scrolled (v0.16 §5): the app's own scrolls
    /// set it; the person's scroll moves it to the message at the top,
    /// which the scroll view keeps, and the point in it, when the width
    /// changes (v0.11, item 67).
    @State private var position = ScrollPosition(idType: String.self)
    /// Where each drawn row sits in the view, for the place the
    /// conversation keeps while another is shown (v0.16 §5).
    @State private var rows = TranscriptRowFrames()
    /// The row a restore scrolled to, while that target is still the
    /// position (fix round 1): a move by any recent person input (a key,
    /// the wheel or VoiceOver) clears it; AppKit's own scroll does not.
    @State private var restoredTop: String?
    /// Whether the transcript was seen at its bottom, kept there when its width changes (v0.11, item 67).
    @State private var scrollMemory = ConversationScrollMemory()
    /// Whether the person is scrolling the transcript (v0.15 task 2b fix
    /// round 1): only its readings move the scroll memory.
    @State private var personScrolling = false
    /// The scroll view's phase, named, for the blank-space diagnostic's line.
    @State private var scrollPhaseName = "idle"
    /// The person's scroll keys, plain wheels and VoiceOver page scrolls,
    /// which may report no scroll phase (v0.15 task 2b fix round 2).
    @State private var personInput = TranscriptPersonInput()
    /// The transcript's width, for the reading column's (v0.11, item 58).
    @State private var transcriptWidth: CGFloat?
    /// The conversation's height, for the docked card's cap (v0.16).
    @State private var conversationHeight: CGFloat?
    /// The column grows with the text (v0.15 §3).
    @Environment(\.textScale) private var textScale
    /// v0.26 (PORT-12): the person's messages whose rows are on screen, for
    /// the markers. A reference the rail observes, so a change redraws only
    /// the rail: redrawing the conversation inside a scroll moved the place.
    @State private var inViewMarkers = MarkersInView()
    /// Review H2: the markers, worked out once per transcript change.
    @State private var markerIndex = MarkerIndex()
    /// v0.26.4 (D4, D5): this view's side of the diagnostics recording; touched only while they are on.
    @State private var recording = ConversationRecording()

    /// How long a marker's jump highlights the message (ruling 19).
    static let highlightDuration: Duration = .milliseconds(1200)
    /// The transcript's top inset: a jump puts the message's row this far below the top.
    static let topInset: CGFloat = 24

    private var items: [TranscriptItem] { model.transcripts[chat] ?? [] }

    /// The chat's folder, for showing the agent's paths relative to it.
    private var folder: String? { model.chats.first { $0.chat == chat }?.folder }

    var body: some View {
        VStack(spacing: 0) {
            transcript
                // v0.26 (PORT-12, ZG3): the markers, in the pane's left margin.
                .overlay(alignment: .topLeading) { markerRail }
                // Y2: pinned over an earlier session's transcript, so the
                // way back is in view however long it is (v0.6; it used to
                // sit at the end, where the composer would be). An inset,
                // not a row above: the transcript's first item starts below
                // the bar, and what scrolls up goes under it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.showsEarlierBar(chat: chat) {
                        EndedSessionBar(chat: chat)
                            .padding(.horizontal, Self.sideInset)
                            .inConversationColumn()
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                            .background(Theme.window)
                    }
                }
            if !model.pinnedCards(for: chat).isEmpty {
                pinnedCards
            }
            // v0.22 (S3): the deployment's messages dock in the same place,
            // above a question or permission card.
            if !model.dockedDeploymentMessages.shown.isEmpty {
                DeploymentMessageDock()
                    .environment(\.dockMaxHeight, conversationHeight.map(DockedCardLayout.maxHeight))
                    .padding(.horizontal, Self.sideInset)
                    .padding(.bottom, 8)
                    .inConversationColumn()
            }
            // v0.25 (ZE3): the sign-in card, docked like a permission card.
            if model.signinWaits[chat] != nil {
                SigninDock(chat: chat)
                    .environment(\.dockMaxHeight, conversationHeight.map(DockedCardLayout.maxHeight))
                    .padding(.horizontal, Self.sideInset)
                    .padding(.bottom, 8)
                    .inConversationColumn()
            }
            // v0.16 (AO1): the docked question or permission card, at the
            // composer's width above it; the composer stays under it.
            if model.dockedCard(for: chat) != nil {
                CardDock(chat: chat, folder: folder)
                    .environment(\.dockMaxHeight, conversationHeight.map(DockedCardLayout.maxHeight))
                    .padding(.horizontal, Self.sideInset)
                    .padding(.bottom, 8)
                    .inConversationColumn()
            }
            if let status = model.status[chat], !status.isEmpty {
                Text(status)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.sideInset)
                    .padding(.bottom, 8)
                    .inConversationColumn()
            }
            if !model.showsEarlierBar(chat: chat) {
                // The running turn's agents or workflow sit on the composer,
                // as wide as it (v0.10 decisions 1 and 2, AF2 and AF3).
                AgentDock(chat: chat, sideInset: Self.sideInset)
                    .inConversationColumn()
                // What the person sent while the agent works, waiting for its next step (v0.11, AG5).
                QueuedMessages(chat: chat, sideInset: Self.sideInset)
                    .inConversationColumn()
                // An ended session is read-only: no composer.
                // The composer draws above the queued cards and the dock:
                // its slash list (v0.11 item 66) rises from the box's top
                // edge and floats over them while it is open.
                InputBar(chat: chat)
                    .id(chat)
                    .padding(.horizontal, Self.sideInset)
                    .inConversationColumn()
                    .padding(.bottom, 16)
                    .zIndex(1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            conversationHeight = $0
            if Diagnostics.isOn { recording.noteWindow(windowSize) }
        }
        .onChange(of: model.sidebarVisible) { _, now in
            if Diagnostics.isOn { recording.note(.sidebar(visible: now)) }
        }
        .onChange(of: textScale) { _, now in
            if Diagnostics.isOn { recording.note(.textScale(Double(now))) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Diagnostics.switched)) { _ in
            // On again inside one poll, the recorders were closed: start afresh.
            stopRecording()
            if Diagnostics.isOn { startRecording() }
        }
    }

    /// S5: a session that followed another opens with the line that says
    /// how the last one ended and when this one started.
    private var sessionDivider: SessionDivider? {
        guard model.isSinglePresentation, let summary = model.summary(of: chat), let parent = summary.parent else { return nil }
        let parentSummary = model.summary(of: parent)
            ?? ChatSummary(chat: parent, folder: summary.folder, alias: nil, state: .stopped, created: summary.created)
        return SessionDivider(parent: SessionPresentation(summary: parentSummary), current: SessionPresentation(summary: summary))
    }

    /// The frame's conversation inset: 32 at the sides, 24 above.
    static let sideInset: CGFloat = 32

    private var transcript: some View {
        ScrollView {
            // Each element brings its own gap above it (v0.13 decision 1):
            // tool rows that follow each other close up into one block.
            let drawn = self.drawn
            let working = model.showsWorkingLine(chat: chat)
            let calling = model.callingCards(in: chat)
            let done = model.doneCards(in: chat)
            let headed = sessionDivider != nil || items.isEmpty
            VStack(alignment: .leading, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let divider = sessionDivider {
                        divider
                    }
                    if items.isEmpty {
                        emptyState
                            .padding(.top, sessionDivider == nil ? 0 : TranscriptSpacing.itemGap)
                    }
                    ForEach(Array(drawn.enumerated()), id: \.element.id) { index, entry in
                        let gap: CGFloat = index == 0
                            ? (headed ? TranscriptSpacing.itemGap : 0)
                            : standsApart(entry) || standsApart(drawn[index - 1])
                                ? TranscriptSpacing.itemGap
                                : TranscriptSpacing.gap(before: entry, after: drawn[index - 1])
                        Group {
                            if entry.id == briefItem, let info = model.thread(of: chat) {
                                BriefBlock(info: info)
                                    .atReplyWidth()
                            } else {
                                TranscriptEntryView(entry: entry, folder: folder, chat: chat)
                            }
                        }
                            .padding(.top, gap)
                            .id(entry.id)
                            .modifier(MarksVoiceOverFocus(input: personInput))
                            .modifier(ReportsRowFrame(rows: rows, id: entry.id))
                    }
                }
                .scrollTargetLayout()
                // v0.26.1: what comes after the rows (a thread calling, a thread
                // done, the working line, the bottom marker) is laid out always,
                // outside the lazy stack. Found in the field: the 1 pt bottom marker
                // on the view's bottom edge was laid out (1 pt), then dropped and
                // estimated (about 200 pt), then laid out again, every frame, and
                // the app froze; nothing small at the end is ever estimated now.
                VStack(alignment: .leading, spacing: 0) {
                    // A thread calling you (AM1): Main only, after the last
                    // item, drawn by the app and never part of the transcript.
                    ForEach(calling) { card in
                        CallingCardView(card: card)
                            .atReplyWidth()
                            .padding(.top, headed || !drawn.isEmpty ? TranscriptSpacing.itemGap : 0)
                            .id("calling:\(card.id)")
                            .modifier(ReportsRowFrame(rows: rows, id: "calling:\(card.id)", isRow: false))
                    }
                    // A thread that finished while you were here (§9.3): the
                    // same app-drawn kind, after the calls.
                    ForEach(done) { card in
                        DoneCardView(card: card)
                            .atReplyWidth()
                            .padding(.top, headed || !drawn.isEmpty || !calling.isEmpty ? TranscriptSpacing.itemGap : 0)
                            .id(card.id)
                            .modifier(ReportsRowFrame(rows: rows, id: card.id, isRow: false))
                    }
                    if working {
                        WorkingLine(activity: model.activity(for: chat), since: model.turnStartedAt[chat])
                            .padding(.top, headed || !drawn.isEmpty ? TranscriptSpacing.itemGap : 0)
                            .id("working")
                            .modifier(ReportsRowFrame(rows: rows, id: "working", isRow: false))
                    }
                    Color.clear.frame(height: 1)
                        .padding(.top, headed || !drawn.isEmpty || working ? TranscriptSpacing.itemGap : 0)
                        .id("bottom")
                }
            }
            // v0.11 (58): the reading column, centred; its items size
            // themselves from its width (`conversationColumn`).
            .frame(maxWidth: ConversationColumn.maxWidth(scale: textScale), alignment: .leading)
            .padding(.horizontal, Self.sideInset)
            .padding(.top, Self.topInset)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(TranscriptScrollViewProbe(input: personInput))
        }
        .environment(\.highlightedMessage, model.highlightedMessage[chat])
        // Fix I-1: the scroller keeps clear of the viewer divider's grip.
        .clearOfViewerGrip()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            ScrollTrace.note("width chat=\(chat) from=\(transcriptWidth.map { Int($0) } ?? -1) to=\(Int(width))")
            transcriptWidth = width
            if Diagnostics.isOn {
                recording.note(.column(width: Int(width)))
                recording.noteWindow(windowSize)
            }
        }
        .onChange(of: model.shownArtifact(for: chat)?.id) { old, new in
            ScrollTrace.note("viewer chat=\(chat) shown from=\(ArtifactToken.of(old) ?? "none") to=\(ArtifactToken.of(new) ?? "none")")
            if Diagnostics.isOn { noteViewer() }
        }
        .onChange(of: model.viewerVisible[chat] ?? false) { _, now in
            ScrollTrace.note("viewer chat=\(chat) visible=\(now)")
            if Diagnostics.isOn { noteViewer() }
        }
        .environment(
            \.conversationColumn,
            transcriptWidth.map { ConversationColumn.width(available: $0, sideInset: Self.sideInset, scale: textScale) })
        .scrollPosition($position, anchor: .top)
        // v0.11 (67): opening the viewer (or a space) narrows the column
        // and every line wraps again; the bottom stays the bottom. Scrolled
        // up, the scroll position above keeps the place (v0.14 fix).
        .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
            TranscriptGeometry(
                width: geometry.containerSize.width,
                content: geometry.contentSize.height,
                offset: geometry.contentOffset.y,
                atBottom: ConversationScrollMemory.isAtBottom(
                    offset: geometry.contentOffset.y, visible: geometry.containerSize.height,
                    content: geometry.contentSize.height),
                visible: geometry.containerSize.height)
        } action: { _, now in
            if ConversationProbe.enabled { ConversationProbe.geometryReadings[chat, default: 0] += 1 }
            noteMarkersInView(visible: now.visible)
            // The marked input's direction decides which readings are
            // the person's (fix round 4; no longer spent by the first).
            // v0.16 spike: `position.isPositionedByUser` stays false for
            // every input here (ConversationScroll.swift), so the person
            // is the scroll phase and the marked input, as in v0.15.
            let target = scrollMemory.observe(
                width: now.width, atBottom: now.atBottom, scrolling: personScrolling,
                marked: personInput.recent, offset: now.offset)
            ScrollTrace.note("read chat=\(chat) offset=\(Int(now.offset)) content=\(Int(now.content)) visible=\(Int(now.visible)) width=\(Int(now.width)) atBottom=\(now.atBottom) scrolling=\(personScrolling) marked=\(String(describing: personInput.recent)) memoryAtBottom=\(scrollMemory.atBottom) target=\(String(describing: target)) edge=\(String(describing: position.edge)) viewID=\(position.viewID(type: String.self) ?? "-")")
            if target == .bottom {
                if ConversationProbe.enabled { ConversationProbe.bottomCorrections[chat, default: 0] += 1 }
                toBottomThroughLastRow()
            } else if !scrollMemory.atBottom, position.edge == .bottom {
                // The person left the end by input with no scroll phase (a
                // key, or VoiceOver): AppKit moved the clip, so the position
                // still says the bottom edge, and SwiftUI would put it
                // back there when the content next grows (found hosted).
                // An empty position leaves the view where it is.
                ScrollTrace.note("move chat=\(chat) clear-position (left the end by input)")
                position = ScrollPosition(idType: String.self)
            } else if let top = restoredTop, position.viewID(type: String.self) == top,
                      personInput.recent != nil, !personScrolling {
                // Fix round 1: the same for the row a restore scrolled to,
                // on any recent person-input mark (key, wheel or VoiceOver);
                // SwiftUI put the view back on it at the next delta.
                ScrollTrace.note("move chat=\(chat) clear-position (restored row released)")
                position = ScrollPosition(idType: String.self)
                restoredTop = nil
            }
        }
        // A conversation opens at its newest message (v0.13, found live
        // 10-31: a resumed session's transcript arrives in one batch and
        // the scroll ran before the lazy stack had laid it out, leaving
        // the view near the top). Anchor at the bottom, and scroll again
        // once the new rows are laid out.
        // v0.26.1: not through size changes while the person scrolls. Then
        // the lazy stack measures each row coming into view (its estimate
        // corrected), and the bottom anchor held the content's bottom still,
        // so the view moved by the difference under the person's hand: the
        // jumps in the field trace. Otherwise the bottom holds as before
        // (a place put back keeps through a delta or a space).
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(personScrolling ? nil : .bottom, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            // `.animating` too (fix round 2): the app's own scrolls are not animated.
            personScrolling = phase != .idle
            ScrollTrace.note("phase chat=\(chat) \(phase)")
            scrollPhaseName = "\(phase)"
            if ConversationProbe.enabled { ConversationProbe.phaseNames[chat, default: []].append("\(phase)") }
            if Diagnostics.isOn, let name = ScrollPhaseName(phase) { recording.note(.phase(name)) }
        }
        // v0.15 task 2b fix round 1: the newest message is followed only
        // at the bottom (scrolled up, a streaming reply no longer pulls
        // the person back down), and once per change: the geometry
        // reading above catches the rows laid out after it. The person's
        // own message always goes to the bottom.
        .onChange(of: followKey) { old, new in
            ScrollTrace.note("follow chat=\(chat) sent-changed=\(new.sent != old.sent) memoryAtBottom=\(scrollMemory.atBottom) byPerson=\(byPerson)")
            // v0.26.4: the follow key holds the items key and the docked card; the
            // recording writes what changed (shapes, sizes of the gateway's events).
            if Diagnostics.isOn {
                if ConversationProbe.enabled {
                    let began = DispatchTime.now().uptimeNanoseconds
                    recording.changed(recordingSnapshot)
                    ConversationProbe.recordingChangeNanos.append(DispatchTime.now().uptimeNanoseconds - began)
                } else {
                    recording.changed(recordingSnapshot)
                }
            }
            if new.sent != old.sent {
                scrollToBottom()
            } else if scrollMemory.atBottom && !byPerson {
                toBottom()
            }
        }
        .task(id: chat) { await watchForBlankSpace() }
        .onChange(of: position) { _, now in
            ScrollTrace.note("position chat=\(chat) edge=\(String(describing: now.edge)) viewID=\(now.viewID(type: String.self) ?? "-") byUser=\(now.isPositionedByUser)")
        }
        .onChange(of: model.markerJump) { _, request in
            if let request, request.chat == chat { jump(to: request.id) }
        }
        // VoiceOver's page scroll is the person's (fix round 2).
        .accessibilityScrollAction { edge in personInput.page(toward: edge) }
        .onAppear {
            if ConversationProbe.enabled { ConversationProbe.rows[chat] = rows }
            rows.traceChat = chat
            ScrollTrace.note("open chat=\(chat) rows=\(drawn.count)")
            personInput.install()
            recording.wanted = true
            if Diagnostics.isOn { startRecording() }
            if let place = model.place(of: chat), !place.atBottom, let saved = place.topItem,
                let top = TranscriptEntry.anchor(saved, in: drawn)
            {
                restore(top: top, at: place.topOffset)
            } else {
                scrollToBottom()
            }
        }
        .onDisappear {
            personInput.remove()
            recording.wanted = false
            stopRecording()
            // Each conversation keeps its own place (v0.16 §5): Main and
            // its threads, or a session opened from History, and back.
            let top = rows.top()
            model.notePlace(
                ConversationPlace(atBottom: scrollMemory.atBottom, topItem: top?.id, topOffset: top?.offset ?? 0),
                chat: chat)
        }
    }

    /// The person's messages as markers (the brief left out), kept until the transcript changes.
    private var markers: [ConversationMarker] {
        markerIndex.markers(key: itemsKey + ":\(items.count)", entries: { drawn }, briefID: briefItem)
    }

    @ViewBuilder
    private var markerRail: some View {
        let markers = self.markers
        if ConversationMarkers.shown(count: markers.count) {
            MarkerRail(
                markers: markers, positions: markerIndex.positions, inView: inViewMarkers,
                scrollView: { [personInput] in personInput.scrollView }
            ) { id in
                model.jumpToMessage(id, chat: chat)
            }
                .padding(.leading, Self.railLeading)
        }
    }

    /// The rail sits this far from the chat pane's leading edge, inside the
    /// 32 pt side margin: the hovered (longest) mark ends at the margin, so the
    /// rail fits at every width and the reading column never moves for it
    /// (Larry 2026-11-08, ZG3/ZG3b).
    static let railLeading: CGFloat = sideInset - ConversationMarkers.railWidth

    /// The person's messages whose rows intersect the visible area.
    private func noteMarkersInView(visible: CGFloat) {
        let markers = self.markers
        if ConversationProbe.enabled { ConversationProbe.railShown[chat] = ConversationMarkers.shown(count: markers.count) }
        let shown = markerIndex.inView(frames: rows.frames, visible: visible)
        if shown != inViewMarkers.ids { inViewMarkers.ids = shown }
        if ConversationProbe.enabled { ConversationProbe.inView[chat] = shown }
    }

    /// v0.26 (PORT-12): a marker's click. The message's row goes to the top
    /// of the view (the transcript's top inset below it), as a restore does,
    /// so the person's next input releases it and a streaming reply below
    /// doesn't pull the view down; the bubble is highlighted briefly.
    private func jump(to id: String) {
        ScrollTrace.note("move chat=\(chat) marker-jump id=\(id)")
        if Diagnostics.isOn { recording.note(.jump(id: id)) }
        scrollMemory.jumped()
        position.scrollTo(id: id, anchor: .top)
        restoredTop = id
        settle(top: id, at: Self.topInset)
        model.highlightedMessage[chat] = id
        let chat = chat
        Task { @MainActor [model] in
            try? await Task.sleep(for: Self.highlightDuration)
            if model.highlightedMessage[chat] == id { model.highlightedMessage[chat] = nil }
        }
    }

    // MARK: The diagnostics recording (v0.26.4, D4 and D5); called only while they are on.

    /// Starts this conversation's recording: `open`, then one shape per drawn
    /// entry. Waits for the view to be in its window (`onAppear` can come first),
    /// so `open` has the window's size.
    private func startRecording() {
        guard recording.recorder == nil else { return }
        Task { @MainActor in
            for _ in 0..<30 where personInput.scrollView?.window == nil {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard recording.wanted, recording.recorder == nil, let recorder = Diagnostics.recorder(for: chat) else { return }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let window = windowSize
            // I4: where the view is; a place being put back (the view has not got there yet)
            // counts as where it is going.
            let top = rows.top()
            let saved = model.place(of: chat)
            let atBottom: Bool, topId: String?, topOffset: Int
            if restoredTop != nil, let saved, !saved.atBottom, let item = saved.topItem {
                (atBottom, topId, topOffset) = (false, item, Int(saved.topOffset.rounded()))
            } else {
                atBottom = top == nil ? true : scrollMemory.atBottom
                topId = top?.id
                topOffset = top.map { Int($0.offset.rounded()) } ?? 0
            }
            let clipHeight = Int((personInput.scrollView?.contentView.bounds.height ?? 0).rounded())
            recording.start(
                recorder,
                open: .open(
                    chat: chat, appVersion: model.appVersion,
                    macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                    window: window, column: Int(transcriptWidth ?? 0),
                    viewerVisible: model.isViewerShown(for: chat), viewerWidth: viewerWidth,
                    sidebarVisible: model.sidebarVisible, textScale: Double(textScale),
                    atBottom: atBottom, topId: topId, topOffset: topOffset, clipHeight: clipHeight),
                window: window, snapshot: recordingSnapshot)
            personInput.onEvent = { [recording] event in recording.input(event) }
        }
    }

    private func stopRecording() {
        recording.stop()
        personInput.onEvent = nil
    }

    /// What the recording diffs on each change; the drawn rows only when it asks.
    private var recordingSnapshot: ConversationRecording.Snapshot {
        ConversationRecording.Snapshot(
            items: items, itemsKey: itemsKey, docked: model.dockedCard(for: chat)?.id,
            currentTurn: model.currentTurn[chat],
            context: {
                ConversationRecording.Context(
                    briefItem: briefItem, divider: sessionDivider != nil,
                    hidden: model.agentActivity[chat]?.startingToolUses ?? [],
                    apart: Set(model.proposals.values.compactMap(\.toolUseId)).union(model.apps.keys))
            },
            drawn: { drawn(from: $0) })
    }

    /// The window's size, `[width, height]`.
    private var windowSize: [Int] {
        guard let window = personInput.scrollView?.window else { return [0, 0] }
        return [Int(window.frame.width), Int(window.frame.height)]
    }

    /// The viewer column's width: what lies right of the transcript in the window, 0 when it is hidden.
    private var viewerWidth: Int {
        guard model.isViewerShown(for: chat), let scroll = personInput.scrollView,
              let content = scroll.window?.contentView else { return 0 }
        return max(0, Int(content.bounds.width - scroll.convert(scroll.bounds, to: nil).maxX))
    }

    /// The viewer's state as it changes, with its width as laid out then; the
    /// settled width follows in the `column` events the change causes.
    private func noteViewer() {
        recording.noteViewer(.viewer(
            visible: model.isViewerShown(for: chat), width: viewerWidth, shown: ArtifactToken.of(model.shownArtifact(for: chat)?.id)))
    }

    /// The field diagnostic for "empty space under the conversation" (v0.16):
    /// twice a second, while this conversation is shown, one log line per
    /// occurrence when rows exist but the view shows none of them, or shows
    /// past the document's end, for over a second with no scroll phase.
    private func watchForBlankSpace() async {
        var watch = TranscriptBlankSpace.Watch()
        var lastPaint: ScrollTrace.Paint?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard let scroll = personInput.scrollView, let document = scroll.documentView else { continue }
            let clip = scroll.contentView.bounds
            // v0.26.4: transcript rows apart from what is drawn under them; the trace's rowsInView counts rows only.
            let frames = Array(rows.frames.values)
            let others = Array(rows.others.values)
            // 0.43.3: what is on screen, when it changes (the blank-until-scrolled report).
            if ScrollTrace.enabled, let paint = ScrollTrace.paint(scroll: scroll, rowFrames: frames, phase: scrollPhaseName),
               paint != lastPaint {
                ScrollTrace.note(paint.line(chat: chat))
                lastPaint = paint
            }
            // v0.26.2: past the end with no scroll phase, back to the end.
            if !byPerson, let top = TranscriptBlankSpace.pastEnd(clip: clip, documentHeight: document.frame.height) {
                ScrollTrace.note("move chat=\(chat) past-end clip=\(Int(clip.maxY)) content=\(Int(document.frame.height))")
                if ConversationProbe.enabled { ConversationProbe.pastEndCorrections[chat, default: 0] += 1 }
                let view = scroll.contentView
                view.scroll(to: NSPoint(x: view.bounds.origin.x, y: top))
                scroll.reflectScrolledClipView(view)
                continue
            }
            let blank = TranscriptBlankSpace.isBlank(
                hasRows: !drawn.isEmpty, rowFrames: frames, otherFrames: others, clip: clip,
                documentHeight: document.frame.height)
            if watch.observe(blank: blank, scrolling: personScrolling, now: Date()) {
                // v0.26.4: at the end, rows once laid out and now none (a field trace, 11-12): the view is
                // moved a few points, as the wheel's first delta did when it brought the rows back in that
                // trace. Not shown hosted, so a nudge that brought no row back is tried again after another
                // grace, three times until the view has settled (rows shown for ten seconds). Only when the
                // conversation was at its end: scrolled up, the place is the person's.
                if !byPerson, scrollMemory.atBottom, frames.isEmpty, rows.hasReported, watch.mayHeal {
                    watch.healed(now: Date())
                    let view = scroll.contentView
                    let top = max(0, clip.origin.y - TranscriptBlankSpace.healNudge)
                    ScrollTrace.note("move chat=\(chat) blank-heal \(watch.heals) nudge to=\(Int(top))")
                    if ConversationProbe.enabled { ConversationProbe.blankHeals[chat, default: 0] += 1 }
                    view.scroll(to: NSPoint(x: view.bounds.origin.x, y: top))
                    scroll.reflectScrolledClipView(view)
                }
                let last = rows.frames.values.max { $0.minY < $1.minY }
                TranscriptBlankSpace.log(
                    TranscriptBlankSpace.line(
                        chat: chat, documentHeight: document.frame.height, clip: clip, lastRow: last,
                        phase: scrollPhaseName, atBottomEdge: position.edge == .bottom))
            }
        }
    }

    /// Whether the readings now are the person's (v0.15 task 2b fix round 2):
    /// a scroll phase, or a recent scroll key, wheel or VoiceOver move. (Fix
    /// round 3: no longer every reading while VoiceOver is on; that took the
    /// layout's settling for the person's again.)
    private var byPerson: Bool {
        personScrolling || personInput.isRecent
    }

    /// The transcript's drawn rows.
    private var drawn: [TranscriptEntry] { drawn(from: 0) }

    /// The drawn rows of the items from `from` on (the recording's tail; `from`
    /// never falls inside a run of tool rows).
    private func drawn(from: Int) -> [TranscriptEntry] {
        TranscriptEntry.entries(items[from...].filter { model.isDrawn($0, in: chat) }) { row in
            // A proposal's card and an app's page stand apart; they split a run.
            model.proposal(forToolUse: row.toolUseId) != nil || model.app(forToolUse: row.toolUseId) != nil
        }
    }

    /// A thread's first message, drawn as its brief (AM3).
    private var briefItem: String? {
        BriefBlock.briefItem(in: items, brief: model.thread(of: chat)?.brief)
    }

    /// The proposal card and a question's pill or record (v0.16) stand
    /// apart from the tool rows around them.
    private func standsApart(_ entry: TranscriptEntry) -> Bool {
        guard case .item(.tool(let row)) = entry else { return false }
        return model.proposal(forToolUse: row.toolUseId) != nil || QuestionRecord.isRecord(row)
    }

    /// To the bottom, and twice: once now, once after the rows are laid out.
    /// Recorded as at the bottom (v0.15 fix round 1): the jump's own
    /// reading is the layout's, so the memory would not see it.
    private func scrollToBottom() {
        ScrollTrace.note("move chat=\(chat) scrollToBottom")
        scrollMemory.followed()
        toBottom()
        Task { @MainActor in
            await Task.yield()
            toBottom()
        }
    }

    /// The app's own scroll to the end (v0.16 §5): the bottom edge, which
    /// SwiftUI keeps as the content and the column change, and drops when
    /// the person scrolls. Not the last row's id: SwiftUI put an id target
    /// back once after the person's first scroll (v0.15 R10, found again
    /// hosted here).
    private func toBottom() {
        ScrollTrace.note("move chat=\(chat) toBottom (edge)")
        position.scrollTo(edge: .bottom)
    }

    /// Back to the end after the column's width changed or the layout moved
    /// it (v0.19 fix): to the last row by its id first, then the bottom edge.
    /// The edge is the lazy stack's estimated content height, and with tool
    /// rows folded the rows not laid out are few and very unlike (a 50 pt
    /// group, a 1000 pt reply): found hosted, narrowing 900 to 640 left the
    /// content at 32053 pt with the rows it drew placed below that end, so
    /// the view at the edge showed none of them. Scrolling to an id lays
    /// that row out where the view is; the edge after it keeps v0.16's
    /// target, which SwiftUI drops when the person scrolls.
    private func toBottomThroughLastRow() {
        ScrollTrace.note("move chat=\(chat) toBottomThroughLastRow")
        position.scrollTo(id: "bottom", anchor: .bottom)
        Task { @MainActor in
            await Task.yield()
            toBottom()
        }
    }

    /// Back to the place this conversation was left at (v0.16 §5): the row
    /// that was at the top, then the point in it, once that row is laid out.
    private func restore(top: String, at offset: CGFloat) {
        ScrollTrace.note("move chat=\(chat) restore top=\(top) at=\(Int(offset))")
        scrollMemory.restored(atBottom: false)
        position.scrollTo(id: top, anchor: .top)
        restoredTop = top
        settle(top: top, at: offset)
    }

    /// Once `top`'s row is laid out, moves the view so its top sits `offset`
    /// below the view's top (a restore, a marker's jump).
    private func settle(top: String, at offset: CGFloat) {
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(16))
                // The person scrolling meanwhile has the last word.
                if byPerson { return }
                guard let frame = rows.frames[top] else { continue }
                let off = frame.minY - offset
                if abs(off) < 0.5 { return }
                guard let scroll = personInput.scrollView else { continue }
                let clip = scroll.contentView
                ScrollTrace.note("move chat=\(chat) settle top=\(top) by=\(Int(off))")
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + off))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    /// The chat's open forms, pinned above the input until answered or
    /// cancelled. The answer goes through the model, which unpins the card
    /// and marks the inline copy. Questions and permission cards dock.
    private var pinnedCards: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.pinnedCards(for: chat)) { card in
                    CardView(card: card, folder: folder, onAnswer: { model.answerCard($0) })
                        .id(card.id)
                }
            }
            .padding(.horizontal, Self.sideInset)
            .padding(.bottom, 12)
            .inConversationColumn()
        }
        .clearOfViewerGrip()
        .frame(maxHeight: 320)
    }

    /// What the transcript follows (v0.15 fix round 1): any change, and
    /// apart from it the person's newest message (the gateway's echo of a send).
    private var followKey: FollowKey {
        let sent = items.last { if case .userText = $0 { true } else { false } }?.id
        return FollowKey(scroll: scrollKey, sent: sent)
    }

    private struct FollowKey: Equatable {
        var scroll: String
        var sent: String?
    }

    /// Changes whenever an item is added or the streaming tail grows.
    private var scrollKey: String {
        let working = model.showsWorkingLine(chat: chat) ? ":w" : ""
        let calling = (model.callingCards(in: chat).map(\.id) + model.doneCards(in: chat).map(\.id))
            .joined(separator: ",")
        // A card docking or leaving changes the transcript's height (v0.16).
        let docked = Self.dockKey(
            card: model.dockedCard(for: chat)?.id, messages: model.dockedDeploymentMessages.shown.map(\.id))
        return itemsKey + working + (calling.isEmpty ? "" : ":c:" + calling) + docked
    }

    /// The docked card's id and the deployment's message cards, for the scroll key.
    static func dockKey(card: String?, messages: [String]) -> String {
        (card.map { ":d:" + $0 } ?? "") + messages.map { ":m:" + $0 }.joined()
    }

    private var itemsKey: String {
        guard let last = items.last else { return "" }
        if case .assistantText(let id, let text, _) = last { return "\(items.count):\(id):\(text.count)" }
        return "\(items.count):\(last.id)"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.isSinglePresentation ? "Session \(chat)" : "Chat #\(chat)")
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            Text(model.isLive(chat: chat) ? "Nothing yet. Say something below." : "Loading the transcript…")
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
        }
    }
}

/// The transcript's width and whether it is at its end, as its scroll
/// geometry changes (v0.11, item 67). v0.15 fix: and the content's height
/// and offset, so the layout moving the end (the rows resolving at a new
/// width, a streamed line) is a reading of its own: the end moved while
/// `atBottom` read false throughout, and nothing followed it.
private struct TranscriptGeometry: Equatable {
    var width: CGFloat
    var content: CGFloat
    var offset: CGFloat
    var atBottom: Bool
    var visible: CGFloat = 0
}

/// One transcript item, by kind.
struct TranscriptItemView: View {
    let item: TranscriptItem
    var folder: String? = nil
    /// The chat the item belongs to: a tool row asks it whether its
    /// permission card is still open.
    var chat: Int? = nil
    @EnvironmentObject private var model: AppModel
    /// The reading column's width, once measured (v0.11, item 58).
    @Environment(\.conversationColumn) private var column
    /// v0.26: the message a marker's jump highlights.
    @Environment(\.highlightedMessage) private var highlighted

    /// Replies and tool rows: 92% of the column, the whole width until it is measured.
    private var replyWidth: CGFloat {
        column.map(ConversationColumn.replyWidth) ?? .infinity
    }

    var body: some View {
        switch item {
        case .userText(let user):
            UserBubble(
                content: BubbleContent(user), maxWidth: column.map(ConversationColumn.bubbleMaxWidth) ?? UserBubble.fallbackMaxWidth,
                via: user.via, onOpen: { [model] path in model.reveal(file: path, in: user.chat) },
                linkSites: model.hello?.linkSites ?? [:],
                at: user.noTime == true ? nil : SessionTime.parse(user.ts), copyText: user.text,
                highlighted: highlighted == item.id,
                onImageLoaded: Diagnostics.isOn ? { [chat, id = item.id] index, height in
                    // Only into a recording already opened (`open` comes first).
                    guard let chat else { return }
                    Diagnostics.recorders[chat]?.note(.imageLoaded(id: id, index: index, height: Int(height.rounded())))
                } : nil)
        case .assistantText(let id, let text, let at):
            MarkdownText(text: text, id: id, at: SessionTime.parse(at))
                .frame(maxWidth: replyWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let row) where QuestionRecord.isRecord(row) && QuestionRecord.answerPairs(for: row) != nil:
            // v0.16 §9.4: an answered question is the person's reply.
            AnswerBubble(
                pairs: QuestionRecord.answerPairs(for: row) ?? [],
                maxWidth: column.map(ConversationColumn.bubbleMaxWidth) ?? UserBubble.fallbackMaxWidth)
        case .tool(let row):
            Group {
                if let proposal = model.proposal(forToolUse: row.toolUseId) {
                    // Main's `open_thread` row is its proposal's card (AM2, AM4).
                    ProposalCard(proposal: proposal)
                } else if let app = model.app(forToolUse: row.toolUseId), let chat {
                    // v0.18 §2.3: an MCP app's page takes the row's place.
                    AppCard(state: app, chat: chat)
                } else if QuestionRecord.isRecord(row) {
                    // v0.16 §3.1: the pill while asking; a decline's one-line record.
                    QuestionRecordView(row: row)
                } else if row.tool == ViewerSteps.markTool {
                    MarkRowView(row: row, chat: chat)
                } else {
                    ToolRowView(
                        row: row, folder: folder,
                        waiting: chat.map { model.permissionCard(chat: $0, toolUseId: row.toolUseId) != nil } ?? false)
                }
            }
                .frame(maxWidth: replyWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .card(let card):
            CardInlineView(card: card, status: model.cardStatus(chat: card.chat, id: card.id))
        case .turnMarker(let marker):
            TurnMarkerView(marker: marker)
        case .compacted:
            CompactedLine()
        case .notice(_, let text):
            NoticeLine(text: text)
        case .agents(let group):
            if let chat {
                AgentGroupView(group: group, chat: chat, folder: folder)
            }
        case .signinContinued(_, let at):
            SigninContinuedLine(at: SessionTime.parse(at))
        }
    }
}

/// The space above a transcript item (v0.13 decision 1): tool rows that
/// follow each other sit `toolRowGap` apart, as one block; everything else
/// keeps the conversation's `itemGap`.
enum TranscriptSpacing {
    static let itemGap: CGFloat = 20
    static let toolRowGap: CGFloat = 2

    static func gap(before item: TranscriptItem, after previous: TranscriptItem) -> CGFloat {
        gap(before: .item(item), after: .item(previous))
    }

    /// A folded run of viewer steps closes up like the tool rows it holds.
    static func gap(before entry: TranscriptEntry, after previous: TranscriptEntry) -> CGFloat {
        entry.isToolRow && previous.isToolRow ? toolRowGap : itemGap
    }
}

/// What the person sent, right-aligned on a tinted background. The text
/// is the gateway's `user.text`. v0.19 (spec §8.1): with a gateway that
/// sends `attachments` apart, images show as thumbnails at the top (up to
/// 160 pt wide, wrapping), the typed text under them, then other files as
/// chips; clicking one opens it in the viewer. An older gateway's text,
/// attachments listed in it, shows as it came. v0.11 (58, AG1): the
/// replies' 15-point text (v0.12), 10 by 16 padding, at most 70% of the
/// reading column; a short message hugs.
struct UserBubble: View {
    let content: BubbleContent
    /// The bubble's widest (`ConversationColumn.bubbleMaxWidth`).
    var maxWidth: CGFloat = fallbackMaxWidth
    /// v0.18: the app that sent this message (`user.text`'s `via`), named under the bubble.
    var via: String? = nil
    /// Open an attachment where the person is looking (`AppModel.reveal`).
    var onOpen: (String) -> Void = { _ in }
    /// The deployment's names for link chips (hello `link_sites`).
    var linkSites: [String: String] = [:]
    /// v0.25 (ZE2): when the message was sent, if that is known; shown on hover under the bubble.
    var at: Date? = nil
    /// What Copy under the bubble takes: the text as typed. Nil draws no hover row.
    var copyText: String? = nil
    /// v0.26 (PORT-12): a marker's jump landed here; the bubble is `accentSoft` for a moment.
    var highlighted: Bool = false
    /// v0.26.4 (D4): an image thumbnail swapped its placeholder for the image:
    /// its index among the images and its laid-out height. Set only while diagnostics are on.
    var onImageLoaded: ((Int, CGFloat) -> Void)? = nil

    /// The bubble's fill: `surface`, or `accentSoft` while highlighted (solid, no fade).
    static func fill(highlighted: Bool) -> Color { highlighted ? Theme.accentSoft : Theme.surface }

    @State private var hovering = false
    @Environment(\.textScale) private var textScale

    /// The space under every person bubble for its hover row (review M2): the row's
    /// height at `scale` (measured 22 pt at 100%, 38 at 200%), rounded up.
    static func hoverRowHeight(scale: CGFloat) -> CGFloat {
        (16 * scale + 6).rounded(.up)
    }

    /// Before the column is measured: 70% of the widest column.
    static let fallbackMaxWidth = ConversationColumn.bubbleMaxWidth(column: ConversationColumn.maxWidth)

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                if !content.images.isEmpty {
                    WrappingRows(spacing: 6, trailing: false) {
                        ForEach(content.images, id: \.self) { path in
                            AttachmentThumbnail(
                                path: path, size: .bubble, onOpen: onOpen,
                                onLoaded: onImageLoaded.map { [images = content.images] report in
                                    { height in report(images.firstIndex(of: path) ?? 0, height) }
                                })
                        }
                    }
                }
                if !content.text.isEmpty {
                    let parts = BubbleLinks.split(content.text, extra: linkSites)
                    if !parts.text.isEmpty {
                        Text(BubbleLinks.attributed(parts.text))
                            .scaledFont(MarkdownText.bodySize)
                            .lineSpacing(MarkdownText.lineSpacing)
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    }
                    if !parts.chips.isEmpty {
                        WrappingRows(spacing: 6, trailing: false) {
                            ForEach(parts.chips, id: \.self) { url in
                                if let chip = LinkSites.chip(for: url, extra: linkSites) {
                                    LinkChip(url: url, site: chip.site, path: chip.path)
                                }
                            }
                        }
                    }
                }
                if !content.files.isEmpty {
                    WrappingRows(spacing: 6, trailing: false) {
                        ForEach(content.files, id: \.self) { path in
                            AttachmentChip(path: path, onOpen: onOpen)
                        }
                    }
                }
            }
            .padding(.horizontal, content.images.isEmpty ? 16 : 10)
            .padding(.vertical, 10)
            .background(Self.fill(highlighted: highlighted), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: maxWidth, alignment: .trailing)
            if let via {
                Text("via \(via)")
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
                    .padding(.trailing, 4)
            }
            // v0.25 §3.1 (review M2): the time and Copy under the bubble, trailing, in a
            // space every person bubble reserves, so its height never depends on the row
            // and nothing overlaps the next item. Bubble, gap and row are one hover zone.
            ZStack(alignment: .trailing) {
                if let copyText {
                    MessageHoverRow(at: at, help: "Copy this message") { copyText }
                        .opacity(hovering ? 1 : 0)
                        .offset(x: 6)
                }
            }
            .frame(height: Self.hoverRowHeight(scale: textScale))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A link to a known site in the person's message (v0.19 §10): the site's
/// name semibold, the start of its path in the second text colour, a link
/// symbol; it opens the URL.
struct LinkChip: View {
    let url: URL
    let site: String
    let path: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 5) {
                Image(systemName: "link").font(Theme.iconFont(11))
                Text(site).scaledFont(12, weight: .semibold)
                if !path.isEmpty {
                    Text("·").scaledFont(12)
                    Text(path).scaledFont(12).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .tip(url.absoluteString)
    }
}

/// The end of a turn (v0.4): nothing for a turn that finished, a
/// one-line note under a stopped or failed one. The markers stay in the
/// model; chat apps draw no rule between turns.
struct TurnMarkerView: View {
    let marker: TurnMarker

    /// Whether an item is drawn at all: a finished turn's marker is not.
    static func isDrawn(_ item: TranscriptItem) -> Bool {
        if case .turnMarker(let marker) = item { return label(marker) != nil }
        return true
    }

    /// `Stopped`, `This turn ended with an error`, or nothing.
    static func label(_ outcome: Outcome) -> String? {
        switch outcome {
        case .done: nil
        case .stopped: "Stopped"
        case .error: "This turn ended with an error"
        }
    }

    /// v0.22.1: a failed turn's own reason when the gateway gave one
    /// ("This conversation's folder no longer exists: …"), else the outcome's line.
    /// v0.25 (ZE3): a turn paused on an expired sign-in reads "Paused: sign-in
    /// ran out" (still after it carried on, ruling 15); one that ended on it,
    /// "Sign-in ran out".
    static func label(_ marker: TurnMarker) -> String? {
        if marker.signinPaused { return SigninPresentation.pausedLabel }
        if marker.outcome == .error, marker.finishReason == SigninPresentation.expiredReason {
            return SigninPresentation.endedLabel
        }
        if marker.outcome == .error, let reason = marker.reason, !reason.isEmpty { return reason }
        return label(marker.outcome)
    }

    var body: some View {
        if let label = Self.label(marker) {
            // A reason may wrap: the icon stays by its first line.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .font(Theme.iconFont(11))
                Text(label)
                    .scaledFont(12)
            }
            .foregroundStyle(colour)
            .accessibilityElement(children: .combine)
        }
    }

    private var icon: String {
        if marker.signinPaused { return "pause" }
        return marker.outcome == .error ? "exclamationmark.triangle" : "stop.circle"
    }

    private var colour: Color {
        if marker.signinPaused { return Theme.wait }
        return marker.outcome == .error ? Theme.deny : Theme.text3
    }
}

/// S5's divider at the top of a session that followed another:
/// `✓ Session 13 · Interview codebook · logged today, 11:40 AM` between two
/// rules, and `Session 14 · started today, 11:42 AM` under it; re-read each
/// minute so a relative time moves (v0.7 decision 1).
struct SessionDivider: View {
    let parent: SessionPresentation
    let current: SessionPresentation

    var body: some View {
        TimelineView(.everyMinute) { context in
            lines(now: context.date)
        }
    }

    private func lines(now: Date) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 6) {
                    if parent.summary.logged == true {
                        Image(systemName: "checkmark")
                            .font(Theme.iconFont(10, weight: .semibold))
                    }
                    Text(parent.parentLine(now: now))
                }
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
                .fixedSize()
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            Text(current.startedSecondLine(now: now))
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The quiet line a compaction leaves (S5): the engine summarized the
/// earlier conversation to make room. Shown, never hidden (design §2.1).
struct CompactedLine: View {
    static let text = "Earlier in this session was summarized to make room."

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.compress.vertical")
                .font(Theme.iconFont(11))
                .foregroundStyle(Theme.text3)
            Text(Self.text)
                .scaledFont(12)
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A quiet line from the gateway (`chat.notice`): an unknown command, say.
/// Not the agent's words, so small and dimmed, with no bubble.
struct NoticeLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(Theme.iconFont(11))
            Text(text)
                .scaledFont(12)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.text3)
        .accessibilityElement(children: .combine)
    }
}

/// Over an ended session opened from "Earlier" (Y2): which session, when
/// it ended, that it is read-only, and the way back to the live one as
/// the primary button.
struct EndedSessionBar: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(Theme.iconFont(12))
                .foregroundStyle(Theme.text3)
            TimelineView(.everyMinute) { context in
                Text(line(now: context.date))
                    .scaledFont(13)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let live = model.backTarget(from: chat) {
                Button { model.open(chat: live) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left")
                        Text("Back to Session \(live)")
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                .tip("Go back to Session \(live)")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

extension EndedSessionBar {
    /// `Session 12 · ended Oct 27, 4:12 PM · read-only`.
    private func line(now: Date) -> String {
        guard let summary = model.summary(of: chat) else { return "Session \(chat) · read-only" }
        return SessionPresentation(summary: summary).endedBarLine(now: now)
    }
}

// MARK: - The reading column (v0.11, item 58)

private struct ConversationColumnKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The conversation's reading column width (`ConversationColumn`),
    /// `nil` until the transcript has been measured.
    var conversationColumn: CGFloat? {
        get { self[ConversationColumnKey.self] }
        set { self[ConversationColumnKey.self] = newValue }
    }
}

extension View {
    /// Cap something that pads itself by the conversation's side insets at
    /// the reading column plus those insets, centred: the composer, the
    /// queued cards, the dock and the status line line up with the replies.
    func inConversationColumn(sideInset: CGFloat = ConversationView.sideInset) -> some View {
        modifier(InConversationColumn(sideInset: sideInset))
    }
}

extension View {
    /// At the replies' width (92% of the reading column), leading: the
    /// thread cards (v0.16) line up with the agent's text.
    func atReplyWidth() -> some View {
        modifier(AtReplyWidth())
    }
}

private struct AtReplyWidth: ViewModifier {
    @Environment(\.conversationColumn) private var column

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: column.map(ConversationColumn.replyWidth) ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `inConversationColumn`, at the text scale the column grows with.
private struct InConversationColumn: ViewModifier {
    let sideInset: CGFloat
    @Environment(\.textScale) private var textScale

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ConversationColumn.outerWidth(sideInset: sideInset, scale: textScale))
            .frame(maxWidth: .infinity)
    }
}

extension EnvironmentValues {
    /// v0.26 (PORT-12): the person's message a marker's jump highlights, by transcript id.
    var highlightedMessage: String? {
        get { self[HighlightedMessageKey.self] }
        set { self[HighlightedMessageKey.self] = newValue }
    }
}

private struct HighlightedMessageKey: EnvironmentKey {
    static var defaultValue: String? { nil }
}

/// Tests only: what a hosted `ConversationView` measured (its rows' frames in
/// the scroll view, whether its marker rail is drawn). Off unless a test turns it on.
@MainActor
enum ConversationProbe {
    static var enabled = false
    static var rows: [Int: TranscriptRowFrames] = [:]
    static var railShown: [Int: Bool] = [:]
    static var inView: [Int: Set<String>] = [:]
    static var bottomCorrections: [Int: Int] = [:]
    static var geometryReadings: [Int: Int] = [:]
    static var pastEndCorrections: [Int: Int] = [:]
    /// v0.26.4: times the blank-space watch nudged a view with no row laid out.
    static var blankHeals: [Int: Int] = [:]
    static var phaseNames: [Int: [String]] = [:]
    /// v0.26.4: main-thread time of each recording diff on a follow-key change.
    static var recordingChangeNanos: [UInt64] = []
}
