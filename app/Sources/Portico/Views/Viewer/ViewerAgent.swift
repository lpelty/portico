import AppKit
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
        static let timedOut = "The viewer didn't answer in 10 s."

        /// "This is a PDF; it can be looked at, not used."
        static func notUsed(kind: String) -> String {
            "This is \(article(kind)) \(kind); it can be looked at, not used."
        }

        /// An outside site off the deployment's allow list (spec §3.6).
        static func outsideSite(_ host: String) -> String {
            "This page (\(host)) can be looked at and scrolled, not used. The deployment's allow list sets which sites the agent can click and type on."
        }

        static func article(_ kind: String) -> String {
            kind.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        }
    }

    weak var model: AppModel?

    /// The chat whose viewer header says "Agent is using the viewer";
    /// `nil` once `labelLinger` has passed since the last action.
    @Published private(set) var actingChat: Int?

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
    }

    /// A native pane the agent reads and scrolls (spec §3.2): a PDF's
    /// view, a text file's text view, or the content of a table.
    private struct NativeRef {
        weak var view: NSView?
        let file: URL
        let table: DelimitedTable?
        let rows: TableRowsSeen?
    }

    private var web: WebPaneRef?
    private weak var paneView: NSView?
    private var native: NativeRef?
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

    init(model: AppModel?) {
        self.model = model
    }

    // MARK: panes

    /// A web pane now shows `load` in `view`.
    func attach(_ view: WKWebView, showing load: WebPane.Load) {
        web = WebPaneRef(view: view, load: load)
    }

    func detach(_ view: WKWebView) {
        if web?.view === view { web = nil }
    }

    /// The view that holds a native pane (image, PDF, text, table), for its snapshot.
    func attachPane(_ view: NSView) {
        paneView = view
    }

    func detachPane(_ view: NSView) {
        if paneView === view { paneView = nil }
    }

    /// A PDF's view, a text file's text view, or (with `table`) a view
    /// the size of a table's content, showing `file`.
    func attachNative(_ view: NSView, file: URL, table: DelimitedTable? = nil, rows: TableRowsSeen? = nil) {
        native = NativeRef(view: view, file: file.standardizedFileURL, table: table, rows: rows)
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
        guard let model else { return fail(act, Message.nothingOpen) }
        guard model.agentCanSee else { return fail(act, Message.settingOff) }
        let chat: Int
        if model.isSinglePresentation {
            chat = model.shownChat ?? act.chat
        } else {
            guard model.shownChat == act.chat else { return fail(act, Message.anotherChat) }
            chat = act.chat
        }
        guard let artifact = model.current[chat] else { return fail(act, Message.nothingOpen) }

        begin(chat)
        defer { end() }
        runChat = chat
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
            return answered(act, answer, otherwise: "Scrolled.")
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
        let image = await snapshot(of: view).map { ViewerResult.Image(data: $0.base64EncodedString()) }
        return ViewerResult(id: act.id, ok: true, text: text, image: image)
    }

    private func click(_ act: ViewerAct, target: String, place: String, in view: WKWebView) async -> ViewerResult {
        guard !target.isEmpty else { return fail(act, "Say what to click: a ref from the last look, or a button's or link's words.") }
        let page = lookedPage ?? ""
        guard await outline(target, page: page, field: false, in: view) else { return fail(act, Message.notFound) }
        let before = view.url
        let answer = await call(
            "return window.__porticoAgent.click(target, page, place)", ["target": target, "page": page, "place": place], in: view) as? [String: Any]
        if let host = answer?["outside"] as? String { return fail(act, Message.outsideSite(host)) }
        if answer?["notFound"] as? Bool == true { return fail(act, Message.notFound) }
        guard answer?["ok"] as? Bool == true else { return answered(act, answer, otherwise: "") }
        let label = (answer?["label"] as? String) ?? target
        return ViewerResult(id: act.id, ok: true, text: "Clicked \(label)." + (await navigated(view, from: before)))
    }

    private func type(_ act: ViewerAct, target: String, place: String, in view: WKWebView) async -> ViewerResult {
        guard !target.isEmpty else { return fail(act, "Say where to type: a ref from the last look, or a field's label.") }
        let text = act.args["text"]?.stringValue ?? ""
        let submit = act.args["submit"] == .bool(true)
        let page = lookedPage ?? ""
        guard await outline(target, page: page, field: true, in: view) else { return fail(act, Message.notFound) }
        let before = view.url
        let answer = await call(
            "return window.__porticoAgent.type(target, text, submit, page, place)",
            ["target": target, "text": text, "submit": submit, "page": page, "place": place], in: view) as? [String: Any]
        if let host = answer?["outside"] as? String { return fail(act, Message.outsideSite(host)) }
        if answer?["notFound"] as? Bool == true { return fail(act, Message.notFound) }
        guard answer?["ok"] as? Bool == true else { return answered(act, answer, otherwise: "") }
        let label = (answer?["label"] as? String) ?? target
        var said = "Typed into \(label)."
        if submit { said += " Pressed Return." }
        return ViewerResult(id: act.id, ok: true, text: said + (await navigated(view, from: before)))
    }

    /// The script's own answer `{ok, text}`, or a not-found.
    private func answered(_ act: ViewerAct, _ answer: [String: Any]?, otherwise: String) -> ViewerResult {
        if answer?["notFound"] as? Bool == true { return fail(act, Message.notFound) }
        let ok = answer?["ok"] as? Bool ?? false
        let text = (answer?["text"] as? String) ?? (ok ? otherwise : "The page didn't answer.")
        return ViewerResult(id: act.id, ok: ok, text: text)
    }

    /// Outline the target in the accent colour for `highlightDuration`
    /// (scrolling it into view first). False when there is no such target.
    private func outline(_ target: String, page: String, field: Bool, in view: WKWebView) async -> Bool {
        guard let box = await call(
            "return window.__porticoAgent.rect(target, page, field)",
            ["target": target, "page": page, "field": field], in: view) as? [String: Any]
        else { return false }
        guard highlightDuration > .zero else { return true }
        let number = { (key: String) in CGFloat((box[key] as? NSNumber)?.doubleValue ?? 0) }
        let zoom = view.pageZoom * view.magnification
        let size = CGSize(width: number("w") * zoom, height: number("h") * zoom)
        let top = number("y") * zoom
        let origin = CGPoint(x: number("x") * zoom, y: view.isFlipped ? top : view.bounds.height - top - size.height)
        let ring = NSView(frame: CGRect(origin: origin, size: size).insetBy(dx: -3, dy: -3))
        ring.wantsLayer = true
        let accent = NSColor(model?.brand.accent ?? Theme.accent)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.layer?.borderColor = accent.cgColor
            ring.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        }
        ring.layer?.borderWidth = 2
        ring.layer?.cornerRadius = 4
        view.addSubview(ring)
        try? await Task.sleep(until: min(ContinuousClock.now + highlightDuration, deadline))
        ring.removeFromSuperview()
        return true
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
    private func ensureScript(in view: WKWebView) async {
        let marker = ViewerAgentScript.marker
        if await call("var a = window.__porticoAgent; return !!a && a.__portico === marker", ["marker": marker], in: view)
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
        _ = await race(in: view) { try? await view.evaluateJavaScript(source, in: nil, contentWorld: .page) }
    }

    /// Run `body` in the page, or `nil` when it fails or the act's
    /// deadline comes first (a page stuck in a loop or a promise that
    /// never settles). The page world, not an isolated one: the script
    /// must see the page's own `console.error` and the elements its
    /// scripts listen on, as the page sees them.
    private func call(_ body: String, _ arguments: [String: Any] = [:], in view: WKWebView) async -> Any? {
        await race(in: view) { try? await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) }
    }

    /// `work`'s answer, or `nil` when the act's deadline comes first.
    private func race(in view: WKWebView, _ work: @escaping @MainActor () async -> Any?) async -> Any? {
        guard ContinuousClock.now < deadline else {
            expired = true
            return nil
        }
        let race = JavaScriptRace()
        let due = deadline
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
            expired = true
            return nil
        }
    }

    private func snapshot(of view: WKWebView) async -> Data? {
        guard let image = try? await view.takeSnapshot(configuration: WKSnapshotConfiguration()) else { return nil }
        return ViewerSnapshot.png(image)
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
            let image = paneSnapshot().map { ViewerResult.Image(data: $0.base64EncodedString()) }
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
    private func paneSnapshot() -> Data? {
        guard let pane = paneView, let content = pane.window?.contentView else { return nil }
        let rect = pane.convert(pane.bounds, to: content)
        guard rect.width >= 1, rect.height >= 1, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        return rep.cgImage.flatMap { ViewerSnapshot.png($0) }
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
    static let marker = "viewer-agent-2"

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

/// The look's image: PNG, the longer side at most 1,600 px (spec §3.2).
enum ViewerSnapshot {
    static let maxSide = 1600

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
    @Entry var viewerAgent: ViewerAgent? = nil
}

/// Registers the view behind a native pane with the agent, for its snapshot.
struct ViewerPaneAnchor: NSViewRepresentable {
    let agent: ViewerAgent

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        agent.attachPane(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

}

/// "Agent is using the viewer" and Stop, in the viewer header while the
/// agent acts (spec §3.1). Stop interrupts the turn, as the composer's does.
struct ViewerActingLabel: View {
    @ObservedObject var agent: ViewerAgent
    let chat: Int
    let accent: Color
    let onStop: () -> Void

    var body: some View {
        if agent.actingChat == chat {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                Text("Agent is using the viewer")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Button {
                    agent.stopActing()
                    onStop()
                } label: {
                    Text("Stop")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 9)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help("Stop the agent")
            }
            .fixedSize()
            .transition(.opacity)
        }
    }
}
