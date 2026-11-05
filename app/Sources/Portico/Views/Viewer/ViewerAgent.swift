import AppKit
import Combine
import PDFKit
import SwiftUI
import WebKit

// MARK: - ViewerAgent

/// Carries out the agent's `viewer.act` in the viewer the person is looking
/// at (v0.12, spec §3.1, §3.2, §3.4) and answers the `viewer.result`. Web
/// pages (HTML, Markdown rendered as a page, a URL) are read and used
/// through `viewer-agent.js`; the other panes can be looked at, not used.
///
/// The viewer is never locked: what the person clicks or scrolls stays,
/// and the next look sees the page as they left it.
@MainActor
final class ViewerAgent: ObservableObject {
    /// What the agent is told, word for word from the spec.
    enum Message {
        static let settingOff = "The person has turned off the agent's view of the viewer in Settings."
        static let anotherChat = "The person is looking at another chat."
        static let nothingOpen = "Nothing is open in the viewer."
        static let notFound = "Not found — look again"
        /// A target not found after the person used the page (v0.14 §6b.4).
        static let personUsed = "The person used the page since your last look; look again."
        /// A ref not followed because the page was loaded again (or another
        /// page put in its place) since the agent's look (v0.14 §6b.4).
        static let pageReloaded = "The page reloaded since your last look; look again."
        /// A click by a heading's words with nothing clickable around it (v0.14 §6b.5).
        static let heading = "That's a heading, not something to click; use its ref."
        static let timedOut = "The viewer didn't answer in 10 s."
        /// A show answered: the file or page is in front and has loaded (v0.17).
        static let shown = "Shown in the viewer."

        /// A show whose page failed to load, with the error's words (v0.17).
        static func notLoaded(_ why: String) -> String {
            "Not loaded: \(why)"
        }

        /// "This is a PDF; it can be looked at, not used."
        static func notUsed(kind: String) -> String {
            "This is \(article(kind)) \(kind); it can be looked at, not used."
        }

        /// An outside site off the deployment's allow list (spec §3.6).
        static func outsideSite(_ host: String) -> String {
            "This page (\(host)) can be looked at and scrolled, not used. The deployment's allow list sets which sites the agent can click and type on."
        }

        /// A mark asked for on a pane that isn't a web page (v0.14).
        static func marksOnWebPages(kind: String) -> String {
            "Marks work on web pages; this is \(article(kind)) \(kind)."
        }

        static let markCount = "Mark 1 to 9 things at a time."

        /// A mark target that is no ref, no listed name and no visible text on the page (v0.17 §3.3).
        static func noVisibleText(_ target: String) -> String {
            "No visible text matches '\(target)'"
        }

        /// A mark by a ref that is on no element of the page, with no reload or input to explain it.
        static func noElement(_ ref: String) -> String {
            "No element \(ref) on this page; look again."
        }

        static func cleared(_ count: Int) -> String {
            "Cleared \(count) mark\(count == 1 ? "" : "s")."
        }

        static func article(_ kind: String) -> String {
            kind.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        }
    }

    weak var model: AppModel?

    /// The chat whose page glows while the agent acts (v0.13);
    /// `nil` once `labelLinger` has passed since the last action.
    @Published private(set) var actingChat: Int?

    /// The page the attached web pane shows, as marks know it, updated as
    /// each load is drawn (the marks list's "THIS PAGE"); `nil` with no
    /// web pane or a page with no address.
    @Published private(set) var currentPage: MarkPage?

    /// How long the target is outlined before a click or typing.
    var highlightDuration: Duration = .milliseconds(600)
    /// How long the acting label stays after the last action.
    var labelLinger: Duration = .milliseconds(1500)
    /// The whole act's time, from its arrival: pane, load, script calls,
    /// highlight and any navigation. Under the gateway's 10 s, so the agent
    /// hears why rather than the gateway giving up first.
    var actWait: Duration = .seconds(9)

    private struct WebPaneRef {
        weak var view: WKWebView?
        let load: WebPane.Load
        /// The pane's coordinator, whose handler knows what its rendered
        /// URLs stand for; `nil` for a view attached without one (tests).
        weak var coordinator: WebPane.Coordinator?
    }

    /// A native pane the agent reads and scrolls (spec §3.2): a PDF's
    /// view, a text file's text view, or the content of a table.
    private struct NativeRef {
        weak var view: NSView?
        let file: URL
        let table: DelimitedTable?
        let rows: TableRowsSeen?
    }

    /// The viewer column holds the Work viewer and, while one is open, a
    /// space over it. The Work viewer stays alive under the space (its page
    /// is the person's and is not loaded again on the way back), so each
    /// pane registers in its own slot and the agent acts in the one shown.
    enum Slot: Hashable, Sendable {
        case work, space
    }

    private struct WeakView {
        weak var view: NSView?
    }

    private var webs: [Slot: WebPaneRef] = [:]
    private var paneViews: [Slot: WeakView] = [:]
    private var natives: [Slot: NativeRef] = [:]

    /// The slot on screen: the space's while one is open, else Work's.
    var activeSlot: Slot { model?.openSpace != nil ? .space : .work }

    private var web: WebPaneRef? { webs[activeSlot] }
    private var paneView: NSView? { paneViews[activeSlot]?.view }
    private var native: NativeRef? { natives[activeSlot] }
    /// Per chat, the page token (`__porticoAgent.page`) of the last look:
    /// refs are only followed on the page that numbered them.
    private(set) var lookedPages: [Int: String] = [:]
    private var actions = 0
    /// Acts run one at a time; this is the last one queued.
    private var queue: Task<Void, Never>?
    /// The act being carried out: its chat and deadline, and whether a
    /// step ran out of time. Safe as state because acts run one at a time.
    private var runChat = 0
    private var deadline = ContinuousClock.now
    private var expired = false

    private var lookedPage: String? {
        get { lookedPages[runChat] }
        set { lookedPages[runChat] = newValue }
    }

    /// The chat of the last act, for drawing marks when no chat is shown
    /// (single presentation before a chat is picked).
    private var lastChat: Int?
    private var marksWatch: AnyCancellable?
    private var slotWatch: AnyCancellable?
    private var redrawQueued = false

    init(model: AppModel?) {
        self.model = model
        // Clear all or Show again from the list redraws the page. The
        // publisher fires before the value lands, so the redraw is queued.
        // A redraw writes found flags back, which publish only on a change,
        // so a redraw leads to at most one more and then stops.
        marksWatch = model?.markStore.$marks.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRedraw() }
        }
        // A space opened or Work again: the page on screen changed, so
        // "THIS PAGE" and the drawn marks follow it.
        slotWatch = model?.$openSpace.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] spaceOpen in
            MainActor.assumeIsolated {
                self?.workPane(hidden: spaceOpen)
                self?.queueRedraw()
            }
        }
    }

    // MARK: panes

    /// A web pane now shows `load` in `view`, in `slot` (by default the
    /// slot on screen).
    func attach(_ view: WKWebView, showing load: WebPane.Load, coordinator: WebPane.Coordinator? = nil, slot: Slot? = nil) {
        webs[slot ?? activeSlot] = WebPaneRef(view: view, load: load, coordinator: coordinator)
    }

    func detach(_ view: WKWebView) {
        guard let slot = webs.first(where: { $0.value.view === view })?.key else { return }
        webs[slot] = nil
        guard slot == activeSlot else { return }
        // Called while SwiftUI takes the pane down: publish after.
        Task { [weak self] in
            guard let self, self.web == nil else { return }
            self.setCurrentPage(nil)
        }
    }

    /// The Work viewer's web page goes under an open space, or comes back
    /// (fix round 1). Hidden, it gives up the keyboard (typing would go
    /// into a page the person cannot see, and count as their use of it)
    /// and its media is suspended; back, its media may play again.
    private func workPane(hidden: Bool) {
        guard let view = webs[.work]?.view else { return }
        view.setAllMediaPlaybackSuspended(hidden, completionHandler: nil)
        guard hidden, let window = view.window, Self.isInside(window.firstResponder, view) else { return }
        // The space's page when it is already there, else nothing in particular.
        if let space = webs[.space]?.view, space.window === window {
            window.makeFirstResponder(space)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    private func setCurrentPage(_ page: MarkPage?) {
        // A page's name can differ by how it was reached; both count here.
        if currentPage?.key != page?.key || currentPage?.name != page?.name { currentPage = page }
    }

    /// The view that holds a native pane (image, PDF, text, table), for its snapshot.
    func attachPane(_ view: NSView, slot: Slot? = nil) {
        paneViews[slot ?? activeSlot] = WeakView(view: view)
    }

    func detachPane(_ view: NSView) {
        for (slot, held) in paneViews where held.view === view { paneViews[slot] = nil }
    }

    /// A PDF's view, a text file's text view, or (with `table`) a view
    /// the size of a table's content, showing `file`.
    func attachNative(_ view: NSView, file: URL, table: DelimitedTable? = nil, rows: TableRowsSeen? = nil, slot: Slot? = nil) {
        natives[slot ?? activeSlot] = NativeRef(view: view, file: file.standardizedFileURL, table: table, rows: rows)
    }

    // MARK: perform

    /// Carry out `act`, after any act before it, within `actWait` of now.
    func perform(_ act: ViewerAct) async -> ViewerResult {
        let due = ContinuousClock.now + actWait
        let previous = queue
        let task = Task { @MainActor [weak self] () -> ViewerResult in
            _ = await previous?.value
            guard let self else { return ViewerResult(id: act.id, ok: false, text: Message.nothingOpen) }
            return await self.performNow(act, due: due)
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func performNow(_ act: ViewerAct, due: ContinuousClock.Instant) async -> ViewerResult {
        // A show only reports that a page loaded, never what is on it: it
        // ignores the "agent can see" switch and draws no glow (v0.17).
        if act.action == .show { return await performShow(act, due: due) }
        // The store keeps at most nine a call; more is refused, not cut.
        if act.action == .mark, !(1...MarkStore.perCall).contains(Self.markItems(act).count) {
            return fail(act, Message.markCount)
        }
        guard let model else { return fail(act, Message.nothingOpen) }
        guard model.agentCanSee else { return fail(act, Message.settingOff) }
        let chat: Int
        if model.isSinglePresentation {
            chat = model.shownChat ?? act.chat
        } else {
            guard model.shownChat == act.chat else { return fail(act, Message.anotherChat) }
            chat = act.chat
        }
        guard let artifact = model.shownArtifact(for: chat) else {
            // Clearing is the store's alone: it needs no page open.
            guard act.action == .clearMarks else { return fail(act, Message.nothingOpen) }
            lastChat = chat
            return ViewerResult(id: act.id, ok: true, text: Message.cleared(model.markStore.clear(chat: chat)))
        }

        begin(chat)
        defer { end() }
        runChat = chat
        lastChat = chat
        deadline = due
        expired = false
        // The agent never drives a viewer the person can't see: the
        // document view gives the window back, and a hidden viewer opens.
        model.closeDocumentView()
        if !model.isViewerShown(for: chat) { model.setViewer(visible: true, for: chat) }

        let shown = ArtifactPresentation(artifact: artifact)
        if !shown.isMissing, let load = WebPane.Load(shown) {
            return await performWeb(act, shown: shown, load: load)
        }
        return await performNative(act, shown: shown)
    }

    /// The agent showed `{artifact, location}` (v0.17 §3.2): answer once it
    /// is in front and, for a web page, has loaded. Auto-open runs as the
    /// `artifact.created` arrives, ahead of the show on the same
    /// connection, so a file not in front now never will be: another chat
    /// on screen, auto-open off for its kind, or not marked to open. That,
    /// and a pane that isn't a web page, answers ok at once. A pane on its
    /// failure page or on a site a link went to loads the file again. A
    /// page that failed answers "Not loaded: <why>"; one still loading at
    /// the deadline answers `timedOut`, which the gateway reads as "Shown;
    /// still loading.".
    private func performShow(_ act: ViewerAct, due: ContinuousClock.Instant) async -> ViewerResult {
        let answered = ViewerResult(id: act.id, ok: true, text: Message.shown)
        guard let model, model.shownChat == act.chat else { return answered }
        let location = act.args["location"]?.stringValue ?? ""
        guard let artifact = model.shownArtifact(for: act.chat), artifact.location == location else { return answered }
        // In front: the viewer is where the person looks, as `show(_:in:)` leaves it.
        model.closeDocumentView()
        let shown = ArtifactPresentation(artifact: artifact)
        guard !shown.isMissing, let load = WebPane.Load(shown) else { return answered }
        deadline = due
        expired = false
        guard let view = await webView(showing: load) else { return fail(act, Message.timedOut) }
        let coordinator = web?.coordinator
        if let coordinator, coordinator.isAway(in: view) {
            coordinator.showAgain(in: view)
        }
        await settle(view)
        if expired || ContinuousClock.now >= deadline { return fail(act, Message.timedOut) }
        if let failure = coordinator?.failure { return fail(act, Message.notLoaded(failure)) }
        return answered
    }

    private func fail(_ act: ViewerAct, _ text: String) -> ViewerResult {
        ViewerResult(id: act.id, ok: false, text: text)
    }

    private func begin(_ chat: Int) {
        actions += 1
        actingChat = chat
    }

    /// The label clears `labelLinger` after the last action, unless
    /// another has started meanwhile.
    private func end() {
        let mark = actions
        let linger = labelLinger
        Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard let self, self.actions == mark else { return }
            self.actingChat = nil
        }
    }

    /// The person pressed Stop: the label goes at once.
    func stopActing() {
        actions += 1
        actingChat = nil
    }

    // MARK: web pages

    private func performWeb(_ act: ViewerAct, shown: ArtifactPresentation, load: WebPane.Load) async -> ViewerResult {
        let result = await performWebSteps(act, shown: shown, load: load)
        // A step that ran out of time makes any answer it led to unreliable.
        return expired || ContinuousClock.now >= deadline ? fail(act, Message.timedOut) : result
    }

    private func performWebSteps(_ act: ViewerAct, shown: ArtifactPresentation, load: WebPane.Load) async -> ViewerResult {
        guard let view = await webView(showing: load) else { return fail(act, Message.timedOut) }
        // The page's `focus()` makes the web view the window's first
        // responder; what the person was typing in keeps the keyboard.
        let window = view.window
        // A text field's shared field editor is torn down when it loses
        // focus; the field itself takes it back.
        var before = window?.firstResponder
        if let editor = before as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSResponder {
            before = owner
        }
        let result = await performWebActs(act, shown: shown, in: view)
        if let window, let before, !Self.isInside(before, view) {
            // WebKit asks for first responder a beat after the script runs.
            for _ in 0..<4 {
                if Self.isInside(window.firstResponder, view) { window.makeFirstResponder(before) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return result
    }

    private static func isInside(_ responder: NSResponder?, _ view: NSView) -> Bool {
        (responder as? NSView)?.isDescendant(of: view) ?? false
    }

    private func performWebActs(_ act: ViewerAct, shown: ArtifactPresentation, in view: WKWebView) async -> ViewerResult {
        await settle(view)
        await ensureScript(in: view)
        let target = act.args["target"]?.stringValue ?? ""
        switch act.action {
        case .look:
            return await look(act, shown: shown, in: view)
        case .click:
            switch await usablePlace(view) {
            case .refused(let text): return fail(act, text)
            case .place(let place): return await click(act, target: target, place: place, in: view)
            }
        case .type:
            switch await usablePlace(view) {
            case .refused(let text): return fail(act, text)
            case .place(let place): return await type(act, target: target, place: place, in: view)
            }
        case .scroll:
            let direction = act.args["direction"]?.stringValue ?? target
            guard !direction.isEmpty else { return fail(act, "Give a direction (up, down, top, bottom) or a target.") }
            let answer = await call(
                "return window.__porticoAgent.scroll(target, page)",
                ["target": direction, "page": lookedPage ?? ""], in: view) as? [String: Any]
            return await answered(act, answer, otherwise: "Scrolled.", targets: [direction], in: view)
        case .mark:
            return await mark(act, in: view)
        case .clearMarks:
            let count = model?.markStore.clear(chat: runChat) ?? 0
            await draw([], chat: runChat, page: nil, in: view, quiet: false)
            return ViewerResult(id: act.id, ok: true, text: Message.cleared(count))
        case .show:
            assertionFailure("a show is answered by performShow")
            return ViewerResult(id: act.id, ok: true, text: Message.shown)
        case .back:
            guard view.canGoBack else { return fail(act, "There's nothing to go back to in the viewer.") }
            view.goBack()
            try? await Task.sleep(for: .milliseconds(100))
            await settle(view)
            return ViewerResult(id: act.id, ok: true, text: "Went back. Now showing \(await location(of: view, shown: shown)).")
        }
    }

    private func look(_ act: ViewerAct, shown: ArtifactPresentation, in view: WKWebView) async -> ViewerResult {
        let read = await call(
            "var a = window.__porticoAgent; return {outline: a.outline(), errors: a.errors(), page: a.page}",
            in: view) as? [String: Any]
        guard let read else { return fail(act, "The page couldn't be read.") }
        lookedPage = read["page"] as? String
        let outline = (read["outline"] as? String) ?? ""
        let errors = (read["errors"] as? [Any])?.map { "\($0)" } ?? []
        var text = "Open: \(await location(of: view, shown: shown))\n\n"
        text += outline.isEmpty ? "Nothing to list: no headings, links, buttons, fields, tables or images.\n" : "\(outline)\n"
        if errors.isEmpty {
            text += "\nPage errors since the last look: none."
        } else {
            text += "\nPage errors since the last look:\n" + errors.map { "- \($0)" }.joined(separator: "\n")
        }
        if let marks = model?.markStore.lookText(chat: runChat, current: await page(of: view)) {
            text += "\n\n" + marks
        }
        let image = await snapshot(of: view)
        return ViewerResult(id: act.id, ok: true, text: text, image: image)
    }

    private func click(_ act: ViewerAct, target: String, place: String, in view: WKWebView) async -> ViewerResult {
        guard !target.isEmpty else { return fail(act, "Say what to click: a ref from the last look, or a button's or link's words.") }
        let page = lookedPage ?? ""
        switch await outline(target, page: page, field: false, in: view) {
        case .shown(let box): await highlight(box, in: view, kind: .click)
        case .missing: return await notFound(act, [target], in: view)
        case .heading: return fail(act, Message.heading)
        }
        let before = view.url
        let answer = await call(
            "return window.__porticoAgent.click(target, page, place)", ["target": target, "page": page, "place": place], in: view) as? [String: Any]
        if let host = answer?["outside"] as? String { return fail(act, Message.outsideSite(host)) }
        if answer?["notFound"] as? Bool == true { return await notFound(act, [target], in: view) }
        if answer?["heading"] as? Bool == true { return fail(act, Message.heading) }
        guard answer?["ok"] as? Bool == true else { return await answered(act, answer, otherwise: "", targets: [target], in: view) }
        let label = (answer?["label"] as? String) ?? target
        return ViewerResult(id: act.id, ok: true, text: "Clicked \(label)." + (await navigated(view, from: before)))
    }

    private func type(_ act: ViewerAct, target: String, place: String, in view: WKWebView) async -> ViewerResult {
        guard !target.isEmpty else { return fail(act, "Say where to type: a ref from the last look, or a field's label.") }
        let text = act.args["text"]?.stringValue ?? ""
        let submit = act.args["submit"] == .bool(true)
        let page = lookedPage ?? ""
        guard case .shown(let box) = await outline(target, page: page, field: true, in: view) else {
            return await notFound(act, [target], in: view)
        }
        await highlight(box, in: view, kind: .type)
        let before = view.url
        let answer = await call(
            "return window.__porticoAgent.type(target, text, submit, page, place)",
            ["target": target, "text": text, "submit": submit, "page": page, "place": place], in: view) as? [String: Any]
        if let host = answer?["outside"] as? String { return fail(act, Message.outsideSite(host)) }
        if answer?["notFound"] as? Bool == true { return await notFound(act, [target], in: view) }
        guard answer?["ok"] as? Bool == true else { return await answered(act, answer, otherwise: "", targets: [target], in: view) }
        let label = (answer?["label"] as? String) ?? target
        var said = "Typed into \(label)."
        if submit { said += " Pressed Return." }
        return ViewerResult(id: act.id, ok: true, text: said + (await navigated(view, from: before)))
    }

    /// "Not found — look again", or why it may not be (v0.14 §6b.4): a ref
    /// among `targets` from a page that has since reloaded (or been
    /// replaced), or the person clicked, typed or scrolled on the page since
    /// the agent's last look.
    private func notFound(_ act: ViewerAct, _ targets: [String], in view: WKWebView) async -> ViewerResult {
        fail(act, await notFoundText(targets, in: view))
    }

    private func notFoundText(_ targets: [String], in view: WKWebView) async -> String {
        if await reloaded(targets, in: view) { return Message.pageReloaded }
        return await personUsed(in: view) ? Message.personUsed : Message.notFound
    }

    /// A ref is one of the page's `eN` numbers, as the script reads it.
    static func isRef(_ target: String) -> Bool {
        target.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /e\d+/) != nil
    }

    /// Whether a ref among `targets` was numbered on a page that is no
    /// longer the one shown: its token differs from the last look's.
    private func reloaded(_ targets: [String], in view: WKWebView) async -> Bool {
        guard let looked = lookedPage, !looked.isEmpty, targets.contains(where: Self.isRef) else { return false }
        let now = await call("var a = window.__porticoAgent; return a ? a.page : null", in: view) as? String
        return now != nil && now != looked
    }

    /// Whether the person clicked, pressed a key or scrolled on the page since the agent's last look.
    private func personUsed(in view: WKWebView) async -> Bool {
        await call("var a = window.__porticoAgent; return !!(a && a.personUsed && a.personUsed())", in: view) as? Bool == true
    }

    /// The script's own answer `{ok, text}`, or a not-found.
    private func answered(
        _ act: ViewerAct, _ answer: [String: Any]?, otherwise: String, targets: [String] = [], in view: WKWebView
    ) async -> ViewerResult {
        if answer?["notFound"] as? Bool == true { return await notFound(act, targets, in: view) }
        let ok = answer?["ok"] as? Bool ?? false
        let text = (answer?["text"] as? String) ?? (ok ? otherwise : "The page didn't answer.")
        return ViewerResult(id: act.id, ok: ok, text: text)
    }

    /// What `outline` found: the target's box, in the web view's
    /// coordinates; nothing; or a heading with nothing clickable around it.
    private enum Outlined { case shown(CGRect), missing, heading }

    /// Find the target's box (scrolling it into view first); `highlight`
    /// then shows it.
    private func outline(_ target: String, page: String, field: Bool, in view: WKWebView) async -> Outlined {
        guard let box = await call(
            "return window.__porticoAgent.rect(target, page, field)",
            ["target": target, "page": page, "field": field], in: view) as? [String: Any]
        else { return .missing }
        if box["heading"] as? Bool == true { return .heading }
        let number = { (key: String) in CGFloat((box[key] as? NSNumber)?.doubleValue ?? 0) }
        let zoom = view.pageZoom * view.magnification
        let size = CGSize(width: number("w") * zoom, height: number("h") * zoom)
        let top = number("y") * zoom
        let origin = CGPoint(x: number("x") * zoom, y: view.isFlipped ? top : view.bounds.height - top - size.height)
        return .shown(CGRect(origin: origin, size: size))
    }

    /// Outline `box` in the accent colour for `highlightDuration` while the
    /// agent's pointer glides to it (plan ruling R-c30): both start
    /// together, and the click or typing runs once both are over, so the
    /// pointer adds no time beyond the outline's own wait.
    private func highlight(_ box: CGRect, in view: WKWebView, kind: AgentPointer.Kind) async {
        // The ring goes on first, so the pointer is drawn above it.
        let ring = highlightDuration > .zero ? ring(around: box, in: view) : nil
        async let pointed: Void = point(at: box, in: view, kind: kind)
        if ring != nil {
            try? await Task.sleep(until: min(ContinuousClock.now + highlightDuration, deadline))
        }
        ring?.removeFromSuperview()
        await pointed
    }

    private func ring(around frame: CGRect, in view: WKWebView) -> NSView {
        let ring = NSView(frame: frame.insetBy(dx: -3, dy: -3))
        ring.wantsLayer = true
        let accent = NSColor(model?.brand.accent ?? Theme.accent)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.layer?.borderColor = accent.cgColor
            ring.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        }
        ring.layer?.borderWidth = 2
        ring.layer?.cornerRadius = 4
        view.addSubview(ring)
        return ring
    }

    /// Whether Reduce Motion is on, for the agent's pointer (injectable for tests).
    var pointerReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The agent's pointer glides to `box` and, for a click, pulses
    /// (v0.18 §4.1, ruling 38); the click or typing runs once it has
    /// arrived. One pointer per web view, kept on it between steps.
    private func point(at box: CGRect, in view: WKWebView, kind: AgentPointer.Kind) async {
        let pointer = view.subviews.lazy.compactMap { $0 as? AgentPointer }.first ?? AgentPointer(reduceMotion: pointerReduceMotion)
        pointer.accent = NSColor(model?.brand.accent ?? Theme.accent)
        await pointer.move(to: box, in: view, kind: kind)
    }

    /// " Now showing <title> — <location>." when the action navigated.
    private func navigated(_ view: WKWebView, from before: URL?) async -> String {
        try? await Task.sleep(for: .milliseconds(150))
        await settle(view)
        guard view.url != before else { return "" }
        return " Now showing \(await location(of: view, shown: nil))."
    }

    /// "<title> — <path or URL>" for what the view shows now.
    private func location(of view: WKWebView, shown: ArtifactPresentation?) async -> String {
        let title = (view.title?.isEmpty == false ? view.title : nil) ?? shown?.title ?? ""
        let place: String
        if let url = view.url, url.isFileURL {
            place = url.path
        } else if let url = view.url, url.scheme == RenderedPageHandler.scheme, let file = shown?.fileURL {
            // An HTML file is served at `/<name>`; a link to another file
            // beside it is that file. A markdown page is at `/`.
            let path = url.path
            place = path.isEmpty || path == "/" ? file.path : file.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst())).path
        } else {
            place = view.url?.absoluteString ?? shown?.artifact.location ?? ""
        }
        return title.isEmpty ? place : "\(title) — \(place)"
    }

    /// Whether the agent may click and type on the page at `url` (spec
    /// §3.6): the agent's own pages (`file:` and the viewer's rendered
    /// pages), local servers, and the deployment's `act_hosts` with their
    /// subdomains. Everything else is look and scroll only.
    static func canAct(url: URL, actHosts: [String]) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "file" || scheme == RenderedPageHandler.scheme { return true }
        guard scheme == "http" || scheme == "https",
            var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        return actHosts.contains { entry in
            let entry = entry.lowercased()
            return !entry.isEmpty && (host == entry || host.hasSuffix("." + entry))
        }
    }

    private enum Place {
        case place(String)
        case refused(String)
    }

    /// Whether the agent may click or type on what `view` shows now: the
    /// page's own `location` (so a redirect or a link to another site is
    /// checked again), and the place the script checks once more at the
    /// moment of acting. No page at all fails closed. Only the top-level
    /// page is checked: the agent's script runs in the main frame only, so
    /// it never reaches into an iframe from another site.
    private func usablePlace(_ view: WKWebView) async -> Place {
        guard view.url != nil,
            let here = await call("return {href: location.href, place: window.__porticoAgent.place()}", in: view) as? [String: Any],
            let href = (here["href"] as? String).flatMap(URL.init(string:)),
            let place = here["place"] as? String
        else { return .refused(Message.nothingOpen) }
        guard Self.canAct(url: href, actHosts: model?.hello?.viewerDefaults?.actHosts ?? []) else {
            return .refused(Message.outsideSite(href.host(percentEncoded: false) ?? href.absoluteString))
        }
        return .place(place)
    }

    // MARK: web helpers

    private func webView(showing load: WebPane.Load) async -> WKWebView? {
        while true {
            if let web, web.load == load, let view = web.view { return view }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Wait until the page has loaded (or the deadline).
    private func settle(_ view: WKWebView) async {
        while ContinuousClock.now < deadline {
            if !view.isLoading,
                await call("return document.readyState", in: view) as? String == "complete"
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The script is installed at document start; a page loaded before
    /// that, made by a view without it, or that replaced
    /// `window.__porticoAgent` with its own (no marker) gets it now.
    private func ensureScript(in view: WKWebView, quiet: Bool = false) async {
        let marker = ViewerAgentScript.marker
        if await call("var a = window.__porticoAgent; return !!a && a.__portico === marker", ["marker": marker], in: view, quiet: quiet)
            as? Bool == true
        {
            return
        }
        guard let source = ViewerAgentScript.source else { return }
        // Evaluated by the app, not by the page's `eval`, which a page's
        // Content-Security-Policy without 'unsafe-eval' would block. The
        // script puts itself in place over a page's object of the same
        // name; nothing is removed first, so a reinstall that runs out of
        // time leaves the page as it was rather than without one.
        _ = await race(in: view, quiet: quiet) { try? await view.evaluateJavaScript(source, in: nil, contentWorld: .page) }
    }

    /// Run `body` in the page, or `nil` when it fails or the act's
    /// deadline comes first (a page stuck in a loop or a promise that
    /// never settles). The page world, not an isolated one: the script
    /// must see the page's own `console.error` and the elements its
    /// scripts listen on, as the page sees them.
    ///
    /// `quiet`: outside an act (a redraw after a load or a store change),
    /// with its own short wait, never marking the act in progress expired.
    private func call(_ body: String, _ arguments: [String: Any] = [:], in view: WKWebView, quiet: Bool = false) async -> Any? {
        await race(in: view, quiet: quiet) { try? await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) }
    }

    /// How long a quiet call waits for the page.
    static let quietWait: Duration = .seconds(3)

    /// `work`'s answer, or `nil` when the act's deadline (or a quiet
    /// call's own wait) comes first.
    private func race(in view: WKWebView, quiet: Bool = false, _ work: @escaping @MainActor () async -> Any?) async -> Any? {
        let due = quiet ? ContinuousClock.now + Self.quietWait : deadline
        guard ContinuousClock.now < due else {
            if !quiet { expired = true }
            return nil
        }
        let race = JavaScriptRace()
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<JavaScriptRace.Answer, Never>) in
            race.continuation = continuation
            Task { @MainActor in
                let value = await work()
                race.finish(.value(JavaScriptRace.Box(value: value)))
            }
            Task { @MainActor in
                try? await Task.sleep(until: due)
                race.finish(.timedOut)
            }
        }
        switch answer {
        case .value(let box): return box.value
        case .timedOut:
            if !quiet { expired = true }
            return nil
        }
    }

    private func snapshot(of view: WKWebView) async -> ViewerResult.Image? {
        guard let image = try? await view.takeSnapshot(configuration: WKSnapshotConfiguration()) else { return nil }
        return ViewerSnapshot.encode(image)
    }

    // MARK: marks (v0.14 §3.2–3.3, §4)

    /// The `mark` act's items, `{target, note?}` each, in order.
    static func markItems(_ act: ViewerAct) -> [(target: String, note: String)] {
        guard case .array(let list)? = act.args["marks"] else { return [] }
        return list.map { item in
            guard case .object(let fields) = item else { return (target: "", note: "") }
            return (target: fields["target"]?.stringValue ?? "", note: fields["note"]?.stringValue ?? "")
        }
    }

    /// Locate each target, keep what was found, draw the page's marks and
    /// scroll to the first new one. Marks change nothing on the page, so
    /// they are allowed on any site (no `usablePlace`).
    private func mark(_ act: ViewerAct, in view: WKWebView) async -> ViewerResult {
        guard let model else { return fail(act, Message.nothingOpen) }
        guard let page = await page(of: view) else { return fail(act, Message.nothingOpen) }
        var located: [(label: String, note: String, locator: MarkLocator)] = []
        var missing: [String] = []
        for item in Self.markItems(act) {
            let answer = await call(
                "return window.__porticoAgent.markLocate(target, page)",
                ["target": item.target, "page": lookedPage ?? ""], in: view) as? [String: Any]
            if answer?["ok"] as? Bool == true, let found = answer?["locator"] as? [String: Any] {
                let locator = MarkLocator(
                    path: found["path"] as? String ?? "", tag: found["tag"] as? String ?? "", text: found["text"] as? String ?? "")
                located.append((label: answer?["label"] as? String ?? item.target, note: item.note, locator: locator))
            } else {
                missing.append(item.target)
            }
        }
        guard !located.isEmpty else { return fail(act, await missedText(missing, in: view, endsWithPeriod: false)) }
        let store = model.markStore
        let added = store.add(
            chat: runChat, page: page, items: located, call: act.id,
            toolUseId: act.args["tool_use_id"]?.stringValue, replace: act.args["replace"] == .bool(true))
        await draw(store.marks(chat: runChat, on: page), chat: runChat, page: page, in: view, quiet: false)
        if let first = added.first {
            _ = await call("return window.__porticoAgent.scrollToMark(n)", ["n": first.number], in: view)
        }
        var text = "Marked " + added.map { "\($0.number) · \($0.label)" }.joined(separator: ", ") + "."
        if !missing.isEmpty { text += " " + (await missedText(missing, in: view, endsWithPeriod: true)) }
        return ViewerResult(id: act.id, ok: true, text: text)
    }

    /// What the agent is told about mark targets not found (Ruling 11, as
    /// refined in review): a ref says why it isn't there — "The page
    /// reloaded…", else "The person used the page…", else "No element eN on
    /// this page; look again." — and text says "No visible text matches
    /// '<target>'"; one sentence per target, a repeated one said once.
    /// Sentences end with a period except, when `endsWithPeriod` is false,
    /// a last no-match sentence (the refusal reads as `noVisibleText` alone).
    private func missedText(_ missing: [String], in view: WKWebView, endsWithPeriod: Bool) async -> String {
        let refs = missing.filter(Self.isRef)
        let refWhy: String? = refs.isEmpty ? nil
            : await reloaded(refs, in: view) ? Message.pageReloaded
            : await personUsed(in: view) ? Message.personUsed
            : nil
        var sentences: [String] = []
        for target in missing {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let sentence = Self.isRef(target) ? (refWhy ?? Message.noElement(trimmed)) : Message.noVisibleText(target)
            if !sentences.contains(sentence) { sentences.append(sentence) }
        }
        return sentences.enumerated().map { index, sentence in
            let last = index == sentences.count - 1
            return sentence.hasSuffix(".") || (last && !endsWithPeriod) ? sentence : sentence + "."
        }.joined(separator: " ")
    }

    /// The page `view` shows, as marks know it: a file path for the app's
    /// rendered pages (an HTML file, or the Markdown file a page was made
    /// from), else the URL without its fragment. The open space's page is
    /// named for the space. `nil` for a page with no address of its own
    /// (`about:blank`, the failure page).
    func page(of view: WKWebView) async -> MarkPage? {
        guard let url = view.url, let scheme = url.scheme?.lowercased() else { return nil }
        let page: MarkPage
        if scheme == RenderedPageHandler.scheme {
            let handler = web?.view === view ? web?.coordinator?.handler : nil
            guard let file = handler?.file(for: url) ?? handler?.source(for: url) else { return nil }
            page = MarkPage(key: file.path, name: file.lastPathComponent)
        } else if ["http", "https", "file"].contains(scheme) {
            let key = Self.withoutFragment(url)
            let path = url.path(percentEncoded: false)
            let name = path.isEmpty || path == "/" ? (url.host(percentEncoded: false) ?? key) : url.lastPathComponent
            page = MarkPage(key: key, name: name)
        } else {
            return nil
        }
        if let space = model?.openSpaceArtifact, Self.pageKey(of: space) == page.key {
            return MarkPage(key: page.key, name: space.title)
        }
        return page
    }

    /// The key a page shown from `artifact` has: its resolved file path
    /// for a file drawn as a web page, its address for a URL.
    private static func pageKey(of artifact: Artifact) -> String? {
        switch artifact.media {
        case .url: return URL(string: artifact.location).map(withoutFragment)
        case .html, .markdown:
            return URL(fileURLWithPath: artifact.location).standardizedFileURL.resolvingSymlinksInPath().path
        default: return nil
        }
    }

    private static func withoutFragment(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    /// The chat whose marks the viewer draws: the shown chat, else the
    /// last act's.
    private var drawChat: Int? { model?.shownChat ?? lastChat }

    /// A page finished loading in a web pane (WebKit calls `didFinish` on
    /// Back as well, from its cache or not): draw that page's marks.
    func pageLoaded(_ view: WKWebView) {
        guard web?.view === view else { return }
        Task { [weak self] in await self?.redraw(view) }
    }

    private func queueRedraw() {
        guard !redrawQueued else { return }
        redrawQueued = true
        Task { [weak self] in
            guard let self else { return }
            self.redrawQueued = false
            if let view = self.web?.view {
                if view.url != nil { await self.redraw(view) }
            } else {
                // No web page on screen (a space closed onto a native pane).
                self.setCurrentPage(nil)
            }
        }
    }

    /// Draw the store's marks for the page `view` shows (none hides the
    /// overlay), and write back which were found.
    private func redraw(_ view: WKWebView) async {
        guard let model else { return }
        await ensureScript(in: view, quiet: true)
        let page = await page(of: view)
        if web?.view === view { setCurrentPage(page) }
        let chat = drawChat
        let list = page.flatMap { page in chat.map { model.markStore.marks(chat: $0, on: page) } } ?? []
        await draw(list, chat: chat ?? 0, page: page, in: view, quiet: true)
    }

    /// Show `list` on the page and record the found flags for `page`,
    /// unless the page moved on meanwhile.
    private func draw(_ list: [Mark], chat: Int, page: MarkPage?, in view: WKWebView, quiet: Bool) async {
        let url = view.url
        let payload: [[String: Any]] = list.map { mark in
            ["n": mark.number, "note": mark.note,
             "locator": ["path": mark.locator.path, "tag": mark.locator.tag, "text": mark.locator.text]]
        }
        let answer = await call(
            "return window.__porticoAgent.showMarks(list, accent)",
            ["list": payload, "accent": accentCSS(for: view)], in: view, quiet: quiet) as? [Any]
        recheck?.cancel()
        recheck = nil
        guard let answer, let page, view.url == url else { return }
        let found = Self.foundFlags(answer)
        model?.markStore.setFound(chat: chat, page: page, found: found)
        guard found.values.contains(false) else { return }
        // The page script watches a short while for what it didn't find (a
        // page that builds its content with script); read back what it drew.
        // A flag that changes publishes, and the redraw that follows starts
        // this again only while something is still missing.
        recheck = Task { [weak self, weak view] in
            var waited: Duration = .zero
            for at in Self.markRecheck {
                try? await Task.sleep(for: at - waited)
                waited = at
                guard !Task.isCancelled, let self, let view, view.url == url else { return }
                guard let status = await self.call("return window.__porticoAgent.markStatus()", in: view, quiet: true) as? [Any],
                      !Task.isCancelled, view.url == url
                else { return }
                let now = Self.foundFlags(status)
                self.model?.markStore.setFound(chat: chat, page: page, found: now)
                if !now.values.contains(false) { return }
            }
        }
    }

    /// When a draw that missed a mark reads back what the page's watch
    /// (about 2 s) found since.
    static let markRecheck: [Duration] = [.milliseconds(300), .milliseconds(1500), .milliseconds(2200)]
    private var recheck: Task<Void, Never>?

    private static func foundFlags(_ answer: [Any]) -> [Int: Bool] {
        var found: [Int: Bool] = [:]
        for case let item as [String: Any] in answer {
            if let number = (item["n"] as? NSNumber)?.intValue, let flag = item["found"] as? Bool { found[number] = flag }
        }
        return found
    }

    /// The brand accent as CSS, in the pane's appearance.
    private func accentCSS(for view: WKWebView) -> String {
        let colour = NSColor(model?.brand.accent ?? Theme.accent)
        var css = ""
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let rgb = colour.usingColorSpace(.sRGB) else { return }
            let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
            css = String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
        }
        return css
    }

    /// Clear all (the list): every mark in the chat goes, and the page
    /// redraws through the store.
    func clearMarks(chat: Int) {
        model?.markStore.clear(chat: chat)
    }

    /// Show again (a tool call's chip): the call's marks come back and the
    /// viewer goes to the first.
    func showAgain(toolUseId: String, chat: Int) {
        guard let first = model?.markStore.showAgain(chat: chat, toolUseId: toolUseId).first else { return }
        goToMark(first, chat: chat)
    }

    /// Scroll to `mark`, going to its page first when the viewer is on
    /// another: the chat's artifact for that page if there is one, else
    /// the page loaded in the attached view (so Back returns).
    func goToMark(_ mark: Mark, chat: Int) {
        Task { [weak self] in await self?.go(to: mark, chat: chat) }
    }

    /// How long going to a mark on another page waits for it to load.
    var markPageWait: Duration = .seconds(5)

    private func go(to mark: Mark, chat: Int) async {
        guard let model else { return }
        // As for an act: the person sees the viewer it goes to. The
        // document view gives the window back and a collapsed viewer opens
        // (its web pane comes back with it).
        model.closeDocumentView()
        if !model.isViewerShown(for: chat) { model.setViewer(visible: true, for: chat) }
        let due = ContinuousClock.now + markPageWait
        let shown = model.shownArtifact(for: chat)
        let shownLoad = shown.flatMap { WebPane.Load(ArtifactPresentation(artifact: $0)) }
        // A web pane for the shown artifact that is on its way back.
        if shownLoad != nil {
            while web?.view == nil, ContinuousClock.now < due { try? await Task.sleep(for: .milliseconds(25)) }
        }
        if let view = web?.view, !view.isLoading, await page(of: view)?.key == mark.page.key {
            await redraw(view)
            _ = await call("return window.__porticoAgent.scrollToMark(n)", ["n": mark.number], in: view, quiet: true)
            return
        }
        let listed = (model.artifacts[chat] ?? []).filter { $0.id != shown?.id }
        if let shown, Self.pageKey(of: shown) == mark.page.key,
           let shownLoad, web?.load == shownLoad, web?.view?.isLoading ?? true {
            // The shown artifact is the mark's page and its pane is loading
            // it (it just came back): wait for it below.
        } else if let artifact = listed.first(where: { Self.pageKey(of: $0) == mark.page.key }) {
            // Another of the chat's artifacts (the pane may be another
            // kind, an image or a PDF): show it in its place.
            model.show(artifact, in: chat)
        } else if let view = web?.view, let url = markURL(mark.page.key) {
            // The shown artifact's page the person followed a link away
            // from, or a page reached from it: loaded in the view, so Back
            // returns.
            view.load(URLRequest(url: url))
        } else {
            model.appendNotice(Self.markPageGaveUp, to: chat)
            return
        }
        while ContinuousClock.now < due {
            try? await Task.sleep(for: .milliseconds(50))
            guard let view = web?.view, !view.isLoading, await page(of: view)?.key == mark.page.key else { continue }
            await redraw(view)
            _ = await call("return window.__porticoAgent.scrollToMark(n)", ["n": mark.number], in: view, quiet: true)
            return
        }
        model.appendNotice(Self.markPageGaveUp, to: chat)
    }

    static let markPageGaveUp = "That page didn't load; the marks are kept for when it does."

    /// What to load for a page key: a file path served by the pane, or the
    /// page's own address.
    private func markURL(_ key: String) -> URL? {
        if key.hasPrefix("/") {
            // A space's file hides the same front matter it hides as a space.
            let isSpace = model?.spaces.contains { space in
                URL(fileURLWithPath: space.location).standardizedFileURL.resolvingSymlinksInPath().path == key
            } ?? false
            return web?.coordinator?.renderedURL(
                for: URL(fileURLWithPath: key), hiding: isSpace ? SpacesPresentation.hiddenFrontMatterKeys : [])
        }
        guard let url = URL(string: key), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return url
    }

    // MARK: other panes

    /// The kind in the agent's words: "image", "PDF", "table", "text file".
    static func kindWord(_ shown: ArtifactPresentation) -> String {
        if shown.isMissing { return "missing file" }
        if shown.tableSeparator != nil { return "table" }
        return switch shown.media {
        case .image: "image"
        case .pdf: "PDF"
        case .text: "text file"
        default: "file"
        }
    }

    private func performNative(_ act: ViewerAct, shown: ArtifactPresentation) async -> ViewerResult {
        let kind = Self.kindWord(shown)
        let readable = !shown.isMissing && (shown.media == .pdf || shown.media == .text)
        switch act.action {
        case .look:
            // Let a pane that just slid open (or a file still loading) draw
            // before it is read and captured.
            let pane = readable ? await nativePane(for: shown) : nil
            try? await Task.sleep(for: .milliseconds(100))
            var text = "Open: \(shown.title) — \(shown.fileURL?.path ?? shown.artifact.location)\nThis is \(Message.article(kind)) \(kind)."
            if shown.media == .image, let file = shown.fileURL, let rep = NSImageRep(contentsOf: file) {
                text += " \(rep.pixelsWide) × \(rep.pixelsHigh) pixels."
            }
            if let pane, let read = Self.read(pane, whole: true) { text += " " + read }
            let image = paneSnapshot()
            return ViewerResult(id: act.id, ok: true, text: text, image: image)
        case .scroll:
            guard readable else { return fail(act, Message.notUsed(kind: kind)) }
            let direction = (act.args["direction"]?.stringValue ?? act.args["target"]?.stringValue ?? "").lowercased()
            guard ["up", "down", "top", "bottom"].contains(direction) else {
                return fail(act, "In \(Message.article(kind)) \(kind), scroll up, down, top or bottom.")
            }
            guard let pane = await nativePane(for: shown), let scroller = Self.scroller(of: pane) else {
                return fail(act, ContinuousClock.now >= deadline ? Message.timedOut : "The \(kind) can't be scrolled.")
            }
            Self.scroll(scroller, direction)
            try? await Task.sleep(for: .milliseconds(50))
            let now = Self.read(pane, whole: false).map { " Now showing \($0)" } ?? ""
            return ViewerResult(id: act.id, ok: true, text: "Scrolled \(direction == "top" || direction == "bottom" ? "to the \(direction)" : direction).\(now)")
        case .click, .type:
            return fail(act, Message.notUsed(kind: kind))
        case .back:
            return fail(act, "There's nothing to go back to in the viewer.")
        case .mark:
            return fail(act, Message.marksOnWebPages(kind: kind))
        case .clearMarks:
            let count = model?.markStore.clear(chat: runChat) ?? 0
            return ViewerResult(id: act.id, ok: true, text: Message.cleared(count))
        case .show:
            assertionFailure("a show is answered by performShow")
            return ViewerResult(id: act.id, ok: true, text: Message.shown)
        }
    }

    /// How long a look or scroll waits for a PDF, text or table pane to
    /// draw. A file that can't be read shows a message pane that never
    /// comes, and the look still answers with the snapshot.
    var nativeWait: Duration = .seconds(3)

    /// The native pane showing `shown`'s file once it has drawn, or `nil`
    /// after `nativeWait` (or at the act's deadline).
    private func nativePane(for shown: ArtifactPresentation) async -> NativeRef? {
        let file = shown.fileURL?.standardizedFileURL
        let due = min(deadline, ContinuousClock.now + nativeWait)
        while true {
            if let native, native.file == file, let view = native.view, view.window != nil { return native }
            if ContinuousClock.now >= due { return nil }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The most text a look carries from a PDF, text file or table.
    static let nativeTextLimit = 4000

    /// What the pane shows now. `whole`: the look's account with the
    /// visible text; otherwise the scroll's short "page 3 of 12." / "lines
    /// 41–80 of 300."
    private static func read(_ pane: NativeRef, whole: Bool) -> String? {
        guard let view = pane.view else { return nil }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        if let pdf = view as? PDFView, let document = pdf.document {
            let count = document.pageCount
            // From the pages' places on screen: `visiblePages` lags a scroll.
            let pages = (0..<count).compactMap(document.page(at:)).filter { page in
                let rect = pdf.convert(page.bounds(for: pdf.displayBox), from: page)
                return rect.intersection(pdf.bounds).height >= 1
            }
            let numbers = pages.map { document.index(for: $0) + 1 }
            guard let first = numbers.first, let last = numbers.last else { return "\(count) page\(count == 1 ? "" : "s")." }
            let span = first == last ? "page \(first)" : "pages \(first)–\(last)"
            guard whole else { return "\(span) of \(count)." }
            let text = pages.compactMap(\.string).joined(separator: "\n\n")
            return "\(count) page\(count == 1 ? "" : "s"); showing \(span).\n\nText on the visible pages:\n" + capped(text)
        }
        if let textView = view as? NSTextView {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
            let string = textView.string as NSString
            let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let lines = string.lineRange(for: characters)
            let first = lineNumber(at: lines.location, in: string)
            let shown = string.substring(with: lines).trimmingCharacters(in: .newlines)
            let last = first + max(0, shown.components(separatedBy: "\n").count - 1)
            let total = lineNumber(at: string.length, in: string)
            let span = "lines \(first)–\(last) of \(total)"
            return whole ? "\(span.prefix(1).uppercased() + span.dropFirst()) are visible:\n" + capped(shown) : "\(span)."
        }
        if let table = pane.table {
            let seen = pane.rows?.visible.filter { $0 < table.rows.count } ?? []
            guard let first = seen.min(), let last = seen.max() else { return whole ? "No rows are visible." : "no rows." }
            let span = "rows \(first + 1)–\(last + 1) of \(table.rows.count)"
            guard whole else { return "\(span)." }
            let lines = [table.header] + table.rows[first...last]
            return "\(span.prefix(1).uppercased() + span.dropFirst()) are visible:\n"
                + capped(lines.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
        }
        return nil
    }

    /// `text` cut to `nativeTextLimit`, saying so when it was.
    private static func capped(_ text: String) -> String {
        guard text.count > nativeTextLimit else { return text }
        return String(text.prefix(nativeTextLimit)) + "\n… cut at 4,000 characters"
    }

    /// The 1-based line `location` falls on.
    private static func lineNumber(at location: Int, in string: NSString) -> Int {
        var count = 1
        var index = 0
        while index < location {
            let found = string.range(of: "\n", range: NSRange(location: index, length: location - index))
            guard found.location != NSNotFound else { break }
            count += 1
            index = found.location + 1
        }
        return count
    }

    /// The scroll view that scrolls the pane.
    private static func scroller(of pane: NativeRef) -> NSScrollView? {
        guard let view = pane.view else { return nil }
        if let pdf = view as? PDFView { return pdf.documentView?.enclosingScrollView }
        return view.enclosingScrollView
    }

    /// Up or down by most of a screen, or to the top or bottom.
    private static func scroll(_ scroller: NSScrollView, _ direction: String) {
        guard let document = scroller.documentView else { return }
        let clip = scroller.contentView
        let flipped = document.isFlipped
        let low = document.frame.minY
        let high = max(low, document.frame.maxY - clip.bounds.height)
        let page = clip.bounds.height * 0.9
        var origin = clip.bounds.origin
        switch direction {
        case "up": origin.y += flipped ? -page : page
        case "down": origin.y += flipped ? page : -page
        case "top": origin.y = flipped ? low : high
        default: origin.y = flipped ? high : low
        }
        origin.y = min(max(origin.y, low), high)
        clip.scroll(to: origin)
        scroller.reflectScrolledClipView(clip)
    }

    /// The native pane as drawn, from the window's own rendering.
    private func paneSnapshot() -> ViewerResult.Image? {
        guard let pane = paneView, let content = pane.window?.contentView else { return nil }
        let rect = pane.convert(pane.bounds, to: content)
        guard rect.width >= 1, rect.height >= 1, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        return rep.cgImage.flatMap { ViewerSnapshot.encode($0) }
    }
}

/// The first of a script's answer and the act's deadline.
@MainActor
private final class JavaScriptRace {
    /// What the page answered (a plist-like value, used on the main actor only).
    struct Box: @unchecked Sendable { let value: Any? }
    enum Answer: Sendable {
        case value(Box)
        case timedOut
    }

    var continuation: CheckedContinuation<Answer, Never>?

    func finish(_ answer: Answer) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

// MARK: - The script

enum ViewerAgentScript {
    /// `window.__porticoAgent.__portico`: what tells the app's script from
    /// a page's own object under that name.
    static let marker = "viewer-agent-4"

    /// `Resources/viewer-agent.js`, read once.
    static let source: String? = AppResources.url(forResource: "viewer-agent", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Installed at document start in the main frame, so page errors are
    /// captured from load.
    static func userScript() -> WKUserScript? {
        source.map { WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true) }
    }
}

// MARK: - ViewerSnapshot

/// The look's image: PNG, the longer side at most 1,600 px (spec §3.2). A PNG past
/// `pngLimit` goes out as JPEG instead; the model API refuses images over 5 MB.
enum ViewerSnapshot {
    static let maxSide = 1600
    static let pngLimit = 3_500_000

    static func encode(_ image: NSImage) -> ViewerResult.Image? {
        let cg = (image.representations.first as? NSBitmapImageRep)?.cgImage
            ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return cg.flatMap { encode($0) }
    }

    static func encode(_ image: CGImage, maxSide: Int = maxSide) -> ViewerResult.Image? {
        guard let png = png(image, maxSide: maxSide) else { return nil }
        if png.count <= pngLimit {
            return ViewerResult.Image(data: png.base64EncodedString())
        }
        guard let rep = NSBitmapImageRep(data: png),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return nil }
        return ViewerResult.Image(data: jpeg.base64EncodedString(), mediaType: "image/jpeg")
    }

    static func png(_ image: NSImage) -> Data? {
        let cg = (image.representations.first as? NSBitmapImageRep)?.cgImage
            ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return cg.flatMap { png($0) }
    }

    static func png(_ image: CGImage, maxSide: Int = maxSide) -> Data? {
        var shown = image
        let longer = max(image.width, image.height)
        if longer > maxSide {
            let scale = Double(maxSide) / Double(longer)
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            shown = scaled
        }
        return NSBitmapImageRep(cgImage: shown).representation(using: .png, properties: [:])
    }
}

// MARK: - SwiftUI plumbing

extension EnvironmentValues {
    /// The agent that acts in the viewer; set by `ViewerView` for its
    /// panes only (the document view's panes are not the agent's).
    var viewerAgent: ViewerAgent? {
        get { self[ViewerAgentKey.self] }
        set { self[ViewerAgentKey.self] = newValue }
    }
    /// Which of the viewer column's two viewers a pane is in (Work's, or
    /// the open space's over it); `nil` outside the viewer column.
    var viewerSlot: ViewerAgent.Slot? {
        get { self[ViewerSlotKey.self] }
        set { self[ViewerSlotKey.self] = newValue }
    }
}

private struct ViewerAgentKey: EnvironmentKey {
    static var defaultValue: ViewerAgent? { nil }
}
private struct ViewerSlotKey: EnvironmentKey {
    static var defaultValue: ViewerAgent.Slot? { nil }
}

/// Registers the view behind a native pane with the agent, for its snapshot.
struct ViewerPaneAnchor: NSViewRepresentable {
    let agent: ViewerAgent

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        agent.attachPane(view, slot: context.environment.viewerSlot)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

}

/// While the agent acts, a 3 pt accent line and a soft inner glow around
/// the page (v0.13 decision 2, Pen AL1), in place of v0.12's header label.
/// It pulses gently (75-100% since v0.14, §6b.3; the glow stronger too),
/// holds steady under Reduce Motion, and goes with the
/// label's timing: `labelLinger` after the last action, at once on Stop.
struct ViewerActingGlow: View {
    @ObservedObject var agent: ViewerAgent
    let chat: Int
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    static let label = "Agent is using the viewer"
    /// One breath, in and out.
    static let period: Double = 1.6
    /// The pulse's floor: 75-100% (v0.13 was 55-100%).
    static let dimOpacity: Double = 0.75
    static let lineWidth: CGFloat = 3
    /// The glow: a band of accent inside the edge, blurred (v0.13: 10 pt at 45%, blur 8).
    static let glowWidth: CGFloat = 14
    static let glowOpacity: Double = 0.7
    static let glowBlur: CGFloat = 10

    var body: some View {
        if agent.actingChat == chat {
            ZStack {
                // The glow breathes; the line stays at full strength so it
                // reads on any page (Larry 10-31: "a little brighter";
                // 11-01: still hard to see, so v0.14 strengthens the glow).
                Rectangle()
                    .strokeBorder(accent.opacity(Self.glowOpacity), lineWidth: Self.glowWidth)
                    .blur(radius: Self.glowBlur)
                    .opacity(reduceMotion ? 1 : (dim ? Self.dimOpacity : 1))
                Rectangle()
                    .strokeBorder(accent, lineWidth: Self.lineWidth)
            }
            .clipped()
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement()
            .accessibilityLabel(Self.label)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: Self.period / 2).repeatForever(autoreverses: true)) { dim = true }
            }
            .onDisappear { dim = false }
        }
    }
}
