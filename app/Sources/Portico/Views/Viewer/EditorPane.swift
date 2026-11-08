import AppKit
import SwiftUI
import WebKit

// MARK: - EditorPage

/// The editor's page: the bundled `editor.html` with viewer.css (read
/// mode's fonts, sizes and colour tokens) and the bundled CodeMirror
/// inlined (v0.20 §5). Served like the read view's Markdown page, by
/// `RenderedPageHandler` under `portico-view://<id>/`, with the edited
/// file's folder as its root: a Markdown file's relative images draw below
/// their lines (the CSP's `img-src 'self'`), dot-files and anything outside
/// the folder are never served. A `file:` base proved unreliable: WebKit's
/// content process could not read images under the temporary folder or
/// the home folder in testing.
enum EditorPage {
    static func html() throws -> String {
        let template = try resource("editor", "html")
        let css = try resource("viewer", "css")
        let script = try resource("editor", "js")
        let comments = try resource("viewer-comments", "js")
        // The stylesheet first: the script is the large part, and nothing
        // inside it is taken for a placeholder.
        return template
            .replacingOccurrences(of: "{{CSS}}", with: css)
            .replacingOccurrences(of: "{{COMMENTS_CSS}}", with: CommentsTheme.css())
            .replacingOccurrences(of: "{{COMMENTS_JS}}", with: comments)
            .replacingOccurrences(of: "{{EDITOR}}", with: script)
    }

    private static func resource(_ name: String, _ ext: String) throws -> String {
        guard let url = AppResources.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw MarkdownPage.Error.missingResource("\(name).\(ext)") }
        return text
    }
}

/// Where a link the person opened from the editor (⌘-click) goes: a web or
/// mail address to the system, a file in the edited file's folder to the
/// viewer, anything else nowhere.
enum EditorLink: Equatable {
    case external(URL)
    case file(String)
    case refused

    static func route(_ url: URL?, folder: URL) -> EditorLink {
        guard let url, let scheme = url.scheme?.lowercased() else { return .refused }
        switch scheme {
        case "http", "https", "mailto":
            return .external(url)
        case "file":
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(prefix) else { return .refused }
            let inside = file.path.dropFirst(prefix.count).split(separator: "/")
            guard !inside.isEmpty, !inside.contains(where: { $0.hasPrefix(".") }) else { return .refused }
            return .file(file.path)
        default:
            return .refused
        }
    }
}

// MARK: - EditorPane

/// The viewer's editor (v0.20 §2.3–2.4): CodeMirror in a `WKWebView`,
/// driven through the page's `portico` global and heard on its `portico`
/// message handler (`ready`, `dirty`, `changed`, `saveNow`). The session
/// owns the text and the saving; the pane only carries it across.
struct EditorPane: NSViewRepresentable {
    @ObservedObject var session: EditSession
    var wrap: Bool
    /// The line to put at the top once the text is in (Edit turned on
    /// again in the same file); 1 is the top.
    var topLine: Int = 1
    /// Esc or ⌘E in the editor: Edit goes off.
    var onStop: () -> Void
    /// A file link in the folder, opened in the viewer.
    var onOpenFile: (String) -> Void
    /// The pane's coordinator, given to the viewer for the top line.
    var onCoordinator: (Coordinator?) -> Void = { _ in }
    /// v0.23: the viewer's comments; the margin works in Edit mode too.
    var comments: ViewerComments? = nil
    @Environment(\.textScale) private var textScale

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.wrap = wrap
        coordinator.scale = textScale
        coordinator.topLine = topLine
        coordinator.onStop = onStop
        coordinator.onOpenFile = onOpenFile
        coordinator.comments = comments
        let view = coordinator.makeWebView()
        coordinator.start(in: view)
        onCoordinator(coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onStop = onStop
        coordinator.onOpenFile = onOpenFile
        if coordinator.scale != textScale {
            coordinator.scale = textScale
            coordinator.applyScale(in: view)
        }
        if coordinator.wrap != wrap {
            coordinator.wrap = wrap
            Task { await coordinator.reconfigure() }
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown(view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        static let handlerName = "portico"

        var session: EditSession?
        var wrap = false
        var scale: CGFloat = 1
        var topLine = 1
        var onStop: () -> Void = {}
        var onOpenFile: (String) -> Void = { _ in }
        /// v0.23: the comments controller; comment actions become changes to this buffer.
        weak var comments: ViewerComments?
        private(set) weak var webView: WKWebView?
        /// The page said `ready`.
        private(set) var ready = false
        /// The session's text is in the editor: only then is the editor's
        /// text the person's (before it, it's an empty document).
        private(set) var holdsText = false
        /// The page's own load is the one navigation allowed.
        private var pageLoading = false
        private var pageURL: URL?
        private var keyMonitor: Any?
        /// Serves the page and the files in the edited file's folder.
        let handler = RenderedPageHandler()

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.setURLSchemeHandler(handler, forURLScheme: RenderedPageHandler.scheme)
            configuration.userContentController.add(EditorMessages(self), name: Self.handlerName)
            configuration.userContentController.add(EditorCommentMessages(self), name: "comments")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            // Read mode's Markdown lets the pane show through; so does this.
            view.setValue(false, forKey: "drawsBackground")
            webView = view
            installKeys()
            return view
        }

        func start(in view: WKWebView) {
            guard let session else { return }
            ready = false
            holdsText = false
            do {
                let page = try EditorPage.html()
                let url = handler.register(page: page, root: session.url.deletingLastPathComponent())
                pageLoading = true
                pageURL = url
                view.load(URLRequest(url: url))
            } catch {
                pageLoading = false
                session.state = .failed("the editor couldn't load (\(error))")
            }
            wireSession(to: view)
        }

        /// The session asks this editor for its text and to replace it.
        private func wireSession(to view: WKWebView) {
            guard let session else { return }
            session.currentText = { [weak self] in await self?.visibleText() }
            session.editorReplace = { [weak self] text, options in
                await self?.replaceAll(text, options) ?? false
            }
        }

        /// The pane is going (another file, Edit off, the viewer closed or
        /// hidden). The session may still need the editor's last text: the
        /// web view is kept, by the session alone, until it has ended.
        func tearDown(_ view: WKWebView) {
            if let comments, comments.editBuffer === self {
                comments.editBuffer = nil
                comments.evaluate = nil
            }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            guard let session else { return }
            if holdsText {
                let retained = view
                session.currentText = {
                    try? await retained.callAsyncJavaScript(
                        "return portico.visibleText();", arguments: [:], in: nil, contentWorld: .page) as? String
                }
            } else {
                session.currentText = nil
            }
            session.editorReplace = nil
        }

        // MARK: the bridge

        func received(_ body: Any, isMainFrame: Bool) {
            guard isMainFrame, let message = body as? [String: Any], let type = message["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                Task { await load() }
            case "dirty":
                if holdsText { session?.markDirty() }
            case "changed", "saveNow":
                if holdsText, let text = message["text"] as? String { session?.textChanged(text) }
            default:
                break
            }
        }

        private func load(keeping line: Int? = nil) async {
            guard let session, let view = webView else { return }
            let options: [String: Any] = [
                "text": session.text,
                "mode": session.mode.rawValue,
                "language": session.language ?? NSNull(),
                "wrap": wrap,
                "scale": Double(scale),
            ]
            let line = line ?? topLine
            let value = try? await view.callAsyncJavaScript(
                loadScript, arguments: ["options": options, "line": line], in: nil, contentWorld: .page)
            // Only a load that finished puts the session's text in the editor.
            // Until then the editor's text is an empty document, never the
            // person's: nothing it says is saved, and an end saves only what
            // the session already holds.
            guard (value as? NSNumber)?.boolValue == true else {
                holdsText = false
                session.notice = "The editor couldn't show the text; nothing was changed"
                return
            }
            holdsText = true
            if session.mode == .markdown, let comments {
                comments.attach(view)
                comments.editBuffer = self
                comments.reload(text: session.text)
                comments.push()
            }
        }

        /// The comments script's messages from this page.
        func commentsMessage(_ body: Any, isMainFrame: Bool) {
            guard isMainFrame, holdsText, let comments, let view = webView else { return }
            comments.attach(view)
            comments.editBuffer = self
            comments.received(body)
        }

        /// The page's load call (a test makes it fail).
        var loadScript =
            "portico.load(options); if (line > 1) portico.scrollToLine(line); portico.view.focus(); return true;"


        /// Settings' Wrap code changed: reconfigured in place (a CodeMirror
        /// compartment), so the text, the cursor and ⌘Z history stay.
        func reconfigure() async {
            guard ready, holdsText, let view = webView else { return }
            _ = try? await view.callAsyncJavaScript(
                "portico.setWrap(wrap); return true;", arguments: ["wrap": wrap], in: nil, contentWorld: .page)
        }

        func applyScale(in view: WKWebView) {
            guard ready else { return }
            view.callAsyncJavaScript(
                "document.documentElement.style.setProperty('--portico-scale', String(scale > 0 ? scale : 1)); return true;",
                arguments: ["scale": Double(scale)], in: nil, in: .page, completionHandler: nil)
        }

        /// The editor's text now; `nil` until it holds the session's text.
        func visibleText() async -> String? {
            guard holdsText, let view = webView else { return nil }
            return try? await view.callAsyncJavaScript(
                "return portico.visibleText();", arguments: [:], in: nil, contentWorld: .page) as? String
        }

        /// The 1-based line at the top of the view; `nil` before it's ready.
        func scrollTopLine() async -> Int? {
            guard holdsText, let view = webView else { return nil }
            let value = try? await view.callAsyncJavaScript(
                "return portico.scrollTopLine();", arguments: [:], in: nil, contentWorld: .page)
            return (value as? NSNumber)?.intValue
        }

        /// The page's `replaceAll`; false when it refused (unsent edits).
        func replaceAll(_ text: String, _ options: EditSession.Replace) async -> Bool {
            guard holdsText, let view = webView else { return false }
            let value = try? await view.callAsyncJavaScript(
                "return portico.replaceAll(text, options) !== false;",
                arguments: ["text": text, "options": [
                    "keepCursorLine": options.keepCursorLine, "keepUndo": options.keepUndo, "force": options.force,
                ]], in: nil, contentWorld: .page)
            return (value as? NSNumber)?.boolValue ?? false
        }

        // MARK: keys

        /// Esc (with no marked text from an input method) and ⌘E while the
        /// editor has the keyboard turn Edit off (§2.2). ⌘E is taken here so
        /// the system's "Use Selection for Find" can't swallow it.
        private func installKeys() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let chord = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let escape = event.keyCode == 53 && chord.isEmpty
                let commandE = chord == .command && event.charactersIgnoringModifiers?.lowercased() == "e"
                guard escape || commandE,
                      let self, let view = self.webView, let window = view.window, event.window === window,
                      let responder = window.firstResponder as? NSView,
                      responder === view || responder.isDescendant(of: view)
                else { return event }
                if escape, (responder as? NSTextInputClient)?.hasMarkedText() == true {
                    return event
                }
                // v0.23: Esc in a comment field cancels that field, not Edit.
                if escape, self.comments?.marginFocused == true { return event }
                self.onStop()
                return nil
            }
        }

        // MARK: links and navigation

        /// Only the page's own load navigates. A link (⌘-click opens it with
        /// `window.open`), a dropped file, a script's `location` change:
        /// all refused here, a link routed by `EditorLink` first.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if pageLoading, navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.navigationType == .other, navigationAction.request.url == pageURL {
                pageLoading = false
                return decisionHandler(.allow)
            }
            if navigationAction.navigationType == .linkActivated {
                open(navigationAction.request.url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            open(navigationAction.request.url)
            return nil
        }

        /// The page's process ended (a crash, memory pressure): load it
        /// again with the session's text; what it hadn't sent is gone, and
        /// the header says so.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            session?.editorRestarted()
            start(in: webView)
        }

        private func open(_ url: URL?) {
            guard let session else { return }
            // A relative link resolves under the page's scheme: back to the
            // file it names in the folder (nil when outside it or a dot-file).
            var target = url
            if let url, url.scheme == RenderedPageHandler.scheme {
                target = handler.file(for: url)
            }
            switch EditorLink.route(target, folder: session.url.deletingLastPathComponent()) {
            case .external(let url): NSWorkspace.shared.open(url)
            case .file(let path): onOpenFile(path)
            case .refused: break
            }
        }
    }
}

/// The page's `portico` handler. Holds the coordinator weakly: the web
/// view's content controller keeps its handlers.
private final class EditorMessages: NSObject, WKScriptMessageHandler {
    weak var coordinator: EditorPane.Coordinator?

    init(_ coordinator: EditorPane.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            coordinator?.received(message.body, isMainFrame: message.frameInfo.isMainFrame)
        }
    }
}

/// The comments script's `comments` handler in the editor's page (v0.23).
private final class EditorCommentMessages: NSObject, WKScriptMessageHandler {
    weak var coordinator: EditorPane.Coordinator?

    init(_ coordinator: EditorPane.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            coordinator?.commentsMessage(message.body, isMainFrame: message.frameInfo.isMainFrame)
        }
    }
}

extension EditorPane.Coordinator: CommentsBuffer {
    func currentText() async -> String? {
        guard holdsText, let view = webView else { return nil }
        return try? await view.callAsyncJavaScript(
            "return portico.commentText();", arguments: [:], in: nil, contentWorld: .page) as? String
    }

    func draftRange() async -> Range<Int>? {
        guard holdsText, let view = webView,
            let value = try? await view.callAsyncJavaScript(
                "var d = portico.draftRange(); return d ? [d.from, d.to] : null;", arguments: [:], in: nil,
                contentWorld: .page) as? [NSNumber], value.count == 2, value[0].intValue <= value[1].intValue
        else { return nil }
        return value[0].intValue..<value[1].intValue
    }

    func applyChange(from: Int, to: Int, insert: String, expectedLength: Int) async -> Bool {
        guard holdsText, let view = webView else { return false }
        let value = try? await view.callAsyncJavaScript(
            "return portico.applyChange(from, to, insert, expectedLength) === true;",
            arguments: ["from": from, "to": to, "insert": insert, "expectedLength": expectedLength],
            in: nil, contentWorld: .page)
        return (value as? NSNumber)?.boolValue ?? false
    }
}

/// The editor with Settings' Wrap code observed, so a change reconfigures it.
struct EditorPaneHost: View {
    @ObservedObject var settings: Settings
    let session: EditSession
    var topLine: Int
    var onStop: () -> Void
    var onOpenFile: (String) -> Void
    var onCoordinator: (EditorPane.Coordinator?) -> Void
    var comments: ViewerComments? = nil

    var body: some View {
        EditorPane(session: session, wrap: settings.wrapCode, topLine: topLine,
                   onStop: onStop, onOpenFile: onOpenFile, onCoordinator: onCoordinator, comments: comments)
    }
}

// MARK: - ViewerEdit

/// One viewer's Edit switch (v0.20 §2.2): off at every open; on, it shows
/// the file's `EditSession`. The session itself is the registry's: turning
/// Edit off, showing another file, closing or hiding the viewer all end it,
/// and one whose text couldn't be saved stays registered (with a recovery
/// copy) and comes back when its file is shown again.
@MainActor
final class ViewerEdit: ObservableObject {
    @Published private(set) var session: EditSession?
    /// Why Edit couldn't turn on ("Can't edit — it isn't UTF-8 text").
    @Published var note: String?
    /// A recovery copy whose text differs from the file, offered back.
    @Published private(set) var restore: EditRecovery.Offer?
    /// In read mode: a recovery copy newer than the shown file, with other
    /// text (left by a quit or a crash), so the offer survives a relaunch.
    /// The header says "Unsaved edits found — Restore".
    @Published private(set) var readOffer: EditRecovery.Offer?

    static let readOfferWords = "Unsaved edits found —"
    static let readOfferAction = "Restore"
    /// The chat whose viewer this is.
    var chat: Int?
    let registry: EditSessions
    /// The shown editor, for its top line.
    weak var editor: EditorPane.Coordinator?
    /// The editor's top line when Edit last went off, per file, so turning
    /// it on again comes back to the same place.
    private var topLines: [String: Int] = [:]
    private var turningOff = false

    init(registry: EditSessions = EditSessions.shared) {
        self.registry = registry
    }

    var isEditing: Bool { session != nil }
    var location: String? { session?.location }

    func topLine(for url: URL) -> Int { topLines[url.path] ?? 1 }

    func toggle(_ artifact: Artifact?) {
        if session != nil {
            Task { await turnOff() }
        } else if let artifact {
            turnOn(artifact)
        }
    }

    static let elsewhere = "Being edited in another viewer"

    /// Another viewer is editing the file at `location` (one session per file).
    func editedElsewhere(_ location: String) -> Bool {
        guard let other = registry.session(for: location) else { return false }
        return other.attached && other !== session
    }

    func turnOn(_ artifact: Artifact) {
        guard session == nil else { return }
        readOffer = nil
        if let existing = registry.session(for: artifact.location) {
            guard !existing.attached else {
                note = Self.elsewhere
                return
            }
            return attach(existing)
        }
        let shown = ArtifactPresentation(artifact: artifact)
        switch FileEditing.editability(for: shown) {
        case .readOnly(let reason):
            note = reason
        case .editable(let mode, let language):
            guard let url = shown.fileURL else { return }
            do {
                let text = try FileEditing.read(url)
                let session = EditSession(
                    url: url, location: artifact.location, loaded: text, mode: mode, language: language, registry: registry)
                attach(session)
                note = nil
                restore = registry.recoveryFolder.flatMap { EditRecovery.offer(for: url, differingFrom: text.text, in: $0) }
            } catch {
                note = "Can't edit — \(FileEditing.Failure.from(error).description)"
            }
        }
    }

    private func attach(_ session: EditSession) {
        session.attached = true
        if let chat { session.chat = chat }
        self.session = session
        registry.attached(session)
    }

    private func detach() -> EditSession? {
        let session = self.session
        session?.attached = false
        self.session = nil
        editor = nil
        restore = nil
        return session
    }

    /// Edit off: the top line noted, the text saved; on a failed save Edit
    /// stays on with "Not saved — <reason>" and Retry.
    func turnOff() async {
        guard let session, !turningOff else { return }
        turningOff = true
        defer { turningOff = false }
        if let top = await editor?.scrollTopLine() { topLines[session.url.path] = top }
        guard await session.end(leaving: true), self.session === session else { return }
        _ = detach()
    }

    /// The viewer now shows `location` (another file, or none: closed,
    /// hidden, its chat gone). The old file's session is ended in the
    /// background; if it can't be saved it stays in the registry with a
    /// recovery copy. A file with a waiting session comes back in Edit.
    func shown(_ location: String?) {
        if session?.location != location { note = nil }
        if let current = session, current.location != location, let old = detach() {
            Task { _ = await old.end() }
        }
        if session == nil, let location, let waiting = registry.waiting(for: location) {
            attach(waiting)
        }
        readOffer = session == nil ? location.flatMap(recoveryOffer(for:)) : nil
    }

    /// A recovery copy for the file at `location` newer than it and with
    /// other text; `nil` for anything else (no folder, not a file path).
    func recoveryOffer(for location: String) -> EditRecovery.Offer? {
        guard let folder = registry.recoveryFolder, location.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: location)
        guard let modified = FileStamp.of(url)?.modified, let text = try? FileEditing.read(url),
              let offer = EditRecovery.offer(for: url, differingFrom: text.text, in: folder),
              offer.date > modified
        else { return nil }
        return offer
    }

    /// The header's Restore in read mode: Edit on, then the copy restored
    /// (undoable, saved, the copy deleted once on disk).
    func restoreFromReadMode(_ artifact: Artifact?) async {
        guard let artifact, readOffer != nil else { return }
        readOffer = nil
        turnOn(artifact)
        guard session != nil, restore != nil else { return }
        await restoreUnsaved()
    }

    /// "Restore unsaved edits": the recovery copy's text replaces the
    /// editor's (undoable) and is saved; then the copy is deleted.
    func restoreUnsaved() async {
        guard let offer = restore, let session, let data = try? Data(contentsOf: offer.url) else { return }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard let text = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { return }
        restore = nil
        await session.restore(text, from: offer.url)
    }

    /// "Discard my edits" (confirmed): the file as on disk.
    func discard() async {
        guard let session else { return }
        await registry.discard(session)
    }

    func dismissRestore() { restore = nil }
}

/// The viewers' Edit switches by chat, for ⌘E.
@MainActor
final class ViewerEditing {
    static let shared = ViewerEditing()
    private var controllers: [Int: Weak] = [:]

    private struct Weak { weak var edit: ViewerEdit? }

    func register(_ edit: ViewerEdit, chat: Int) {
        controllers[chat] = Weak(edit: edit)
    }

    func controller(for chat: Int) -> ViewerEdit? { controllers[chat]?.edit }

    /// ⌘E: whether the shown file can be edited; spaces never.
    static func canToggle(artifact: Artifact?, spaceOpen: Bool) -> Bool {
        guard !spaceOpen, let artifact else { return false }
        let shown = ArtifactPresentation(artifact: artifact)
        return !shown.isMissing && FileEditing.editability(for: shown).canEdit
    }
}

// MARK: - Header parts

/// The header's Edit toggle: a square and pencil (a bare pencil reads as
/// a slash at this size), accent while on (as Focus is).
struct ViewerEditToggle: View {
    let on: Bool
    let editability: Editability
    let accent: Color
    let action: () -> Void

    var body: some View {
        let enabled = editability.canEdit || on
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(Theme.iconFont(ViewerHeader.iconSize, weight: ViewerHeader.iconWeight))
                .frame(width: ViewerHeader.glyphSide, height: ViewerHeader.glyphSide)
                .foregroundStyle(on ? accent : (enabled ? Theme.text2 : Theme.text3))
                .frame(width: ViewerHeader.buttonHeight, height: ViewerHeader.buttonHeight)
                .background(on ? Theme.accentSoft : Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(on ? accent : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .disabled(!enabled)
        .tip(Self.help(on: on, editability: editability))
        .accessibilityLabel(on ? "Stop editing" : "Edit")
    }

    static func help(on: Bool, editability: Editability) -> String {
        if on { return "Stop editing (⌘E or Esc); saves first" }
        switch editability {
        case .editable: return "Edit this file (⌘E)"
        case .readOnly(let reason): return reason
        }
    }
}

/// "Editing · Saved", "Editing · Saving…", "Editing · Not saved" (the
/// agent changed the file), or "Not saved — <reason>" in deny red with
/// Retry (§2.2). A notice (a recovery copy, a held quit) replaces the
/// words in deny red, the state in its tip.
struct ViewerEditStatus: View {
    @ObservedObject var session: EditSession
    /// Discard my edits (fix round 2), confirmed inline.
    var onDiscard: () -> Void = {}
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 6) {
            if let notice = session.notice {
                Text(notice)
                    .scaledFont(12)
                    .foregroundStyle(Theme.deny)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tip(Self.words(for: session.state) + " · " + notice)
            } else {
                Text(Self.words(for: session.state))
                    .scaledFont(12)
                    .foregroundStyle(session.isFailed ? Theme.deny : Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if session.isFailed {
                Button("Retry") { Task { await session.saveNow() } }
                    .buttonStyle(.link)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.deny)
                    .fixedSize()
            }
            if session.isFailed || session.state == .paused {
                Button(confirming ? DiscardConfirm.confirmTitle : DiscardConfirm.title) {
                    if confirming {
                        confirming = false
                        onDiscard()
                    } else {
                        confirming = true
                    }
                }
                .buttonStyle(.link)
                .scaledFont(12)
                .foregroundStyle(confirming ? Theme.deny : Theme.text2)
                .fixedSize()
                .tip("Go back to the file as it is on disk")
                .task(id: confirming) {
                    guard confirming else { return }
                    try? await Task.sleep(for: DiscardConfirm.window)
                    confirming = false
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    static func words(for state: EditSession.SaveState) -> String {
        switch state {
        case .saved: "Editing · Saved"
        case .saving: "Editing · Saving…"
        case .failed(let reason): "Not saved — \(reason)"
        case .paused: "Editing · Not saved"
        }
    }
}

/// The two-step Discard: the button asks "sure?" for four seconds; no modal.
enum DiscardConfirm {
    static let title = "Discard my edits"
    static let confirmTitle = "Discard — sure?"
    static let window: Duration = .seconds(4)
}

/// The bar over the page when the agent changed the file while the person
/// had edits (§2.6): Keep mine, Use the agent's. Autosave waits for one.
struct EditConflictBar: View {
    @ObservedObject var session: EditSession

    static let message = "The agent changed this file while you were editing"

    var body: some View {
        if session.conflict != nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.iconFont(12, weight: .medium))
                    .foregroundStyle(Theme.wait)
                Text(Self.message)
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Theme.wait)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                barButton("Keep mine", help: "Save your version over the agent's") { Task { await session.keepMine() } }
                barButton("Use the agent's", help: "Show the agent's version; ⌘Z brings yours back while Edit is on") {
                    Task { await session.useTheirs() }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Theme.waitSoft)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    private func barButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(12)
                .foregroundStyle(Theme.text)
                .padding(.vertical, 3)
                .padding(.horizontal, 9)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .tip(help)
    }
}

/// "Restore unsaved edits" over the page, when a recovery copy newer than
/// the file exists (fix round 1, ruling B).
struct EditRestoreBar: View {
    @ObservedObject var edit: ViewerEdit

    var body: some View {
        if let offer = edit.restore {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.iconFont(12, weight: .medium))
                    .foregroundStyle(Theme.text2)
                Text("Unsaved edits from \(offer.date.formatted(date: .abbreviated, time: .shortened))")
                    .scaledFont(12)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tip(EditRecovery.display(offer.url))
                Spacer(minLength: 8)
                Button("Restore unsaved edits") { Task { await edit.restoreUnsaved() } }
                    .buttonStyle(.link)
                    .scaledFont(12, weight: .semibold)
                    .fixedSize()
                Button("Dismiss") { edit.dismissRestore() }
                    .buttonStyle(.link)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }
}
