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
        // The stylesheet first: the script is the large part, and nothing
        // inside it is taken for a placeholder.
        return template
            .replacingOccurrences(of: "{{CSS}}", with: css)
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
    /// Esc in the editor: Edit goes off.
    var onEscape: () -> Void
    /// A file link in the folder, opened in the viewer.
    var onOpenFile: (String) -> Void
    /// The pane's coordinator, given to the viewer for the top line.
    var onCoordinator: (Coordinator?) -> Void = { _ in }
    @Environment(\.textScale) private var textScale

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.wrap = wrap
        coordinator.scale = textScale
        coordinator.topLine = topLine
        coordinator.onEscape = onEscape
        coordinator.onOpenFile = onOpenFile
        let view = coordinator.makeWebView()
        coordinator.start(in: view)
        onCoordinator(coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEscape = onEscape
        coordinator.onOpenFile = onOpenFile
        if coordinator.scale != textScale {
            coordinator.scale = textScale
            coordinator.applyScale(in: view)
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
        var onEscape: () -> Void = {}
        var onOpenFile: (String) -> Void = { _ in }
        private(set) weak var webView: WKWebView?
        private(set) var ready = false
        /// The page's own load is the one navigation allowed.
        private var pageLoading = false
        private var pageURL: URL?
        private var escapeMonitor: Any?
        /// Serves the page and the files in the edited file's folder.
        let handler = RenderedPageHandler()

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.setURLSchemeHandler(handler, forURLScheme: RenderedPageHandler.scheme)
            configuration.userContentController.add(EditorMessages(self), name: Self.handlerName)
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            // Read mode's Markdown lets the pane show through; so does this.
            view.setValue(false, forKey: "drawsBackground")
            webView = view
            installEscape()
            return view
        }

        func start(in view: WKWebView) {
            guard let session else { return }
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
        }

        func tearDown(_ view: WKWebView) {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
            if session?.currentText != nil { session?.currentText = nil }
            webView = nil
        }

        // MARK: the bridge

        func received(_ body: Any, isMainFrame: Bool) {
            guard isMainFrame, let message = body as? [String: Any], let type = message["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                load()
            case "dirty":
                session?.markDirty()
            case "changed":
                if let text = message["text"] as? String { session?.textChanged(text) }
            case "saveNow":
                if let text = message["text"] as? String { session?.textChanged(text) }
            default:
                break
            }
        }

        private func load() {
            guard let session, let view = webView else { return }
            let options: [String: Any] = [
                "text": session.text,
                "mode": session.mode.rawValue,
                "language": session.language ?? NSNull(),
                "wrap": wrap,
                "scale": Double(scale),
            ]
            let line = topLine
            view.callAsyncJavaScript(
                "portico.load(options); if (line > 1) portico.scrollToLine(line); portico.view.focus(); return true;",
                arguments: ["options": options, "line": line], in: nil, in: .page, completionHandler: nil)
            session.currentText = { [weak self] in await self?.visibleText() }
        }

        func applyScale(in view: WKWebView) {
            guard ready else { return }
            view.callAsyncJavaScript(
                "document.documentElement.style.setProperty('--portico-scale', String(scale > 0 ? scale : 1)); return true;",
                arguments: ["scale": Double(scale)], in: nil, in: .page, completionHandler: nil)
        }

        /// The editor's text now; `nil` before it's ready.
        func visibleText() async -> String? {
            guard ready, let view = webView else { return nil }
            return try? await view.callAsyncJavaScript(
                "return portico.visibleText();", arguments: [:], in: nil, contentWorld: .page) as? String
        }

        /// The 1-based line at the top of the view; `nil` before it's ready.
        func scrollTopLine() async -> Int? {
            guard ready, let view = webView else { return nil }
            let value = try? await view.callAsyncJavaScript(
                "return portico.scrollTopLine();", arguments: [:], in: nil, contentWorld: .page)
            return (value as? NSNumber)?.intValue
        }

        // MARK: Esc

        /// Esc while the editor has the keyboard turns Edit off (§2.2).
        private func installEscape() {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
                else { return event }
                guard let self, let view = self.webView, let window = view.window, event.window === window,
                      let responder = window.firstResponder as? NSView,
                      responder === view || responder.isDescendant(of: view)
                else { return event }
                self.onEscape()
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

// MARK: - ViewerEdit

/// One viewer's Edit switch (v0.20 §2.2): off at every open; on, it holds
/// the file's `EditSession`. Turning it off saves first, and stays on when
/// the save fails, so the text is never dropped by a toggle.
@MainActor
final class ViewerEdit: ObservableObject {
    @Published private(set) var session: EditSession?
    /// Why Edit couldn't turn on ("Can't edit — it isn't UTF-8 text").
    @Published var note: String?
    /// The artifact location the session belongs to.
    private(set) var location: String?
    /// The shown editor, for its top line.
    weak var editor: EditorPane.Coordinator?
    /// The editor's top line when Edit last went off, per file, so turning
    /// it on again comes back to the same place.
    private var topLines: [String: Int] = [:]
    private var turningOff = false

    var isEditing: Bool { session != nil }

    func topLine(for url: URL) -> Int { topLines[url.path] ?? 1 }

    func toggle(_ artifact: Artifact?) {
        if session != nil {
            Task { await turnOff() }
        } else if let artifact {
            turnOn(artifact)
        }
    }

    func turnOn(_ artifact: Artifact, registry: EditSessions? = EditSessions.shared) {
        guard session == nil else { return }
        let shown = ArtifactPresentation(artifact: artifact)
        guard case .editable(let mode, let language) = FileEditing.editability(for: shown), let url = shown.fileURL else { return }
        do {
            let text = try FileEditing.read(url)
            session = EditSession(url: url, loaded: text, mode: mode, language: language, registry: registry)
            location = artifact.location
            note = nil
        } catch {
            note = "Can't edit — \(FileEditing.Failure.from(error).description)"
        }
    }

    /// Edit off: the top line noted, the text saved; on a failed save Edit
    /// stays on with "Not saved — <reason>" and Retry.
    func turnOff() async {
        guard let session, !turningOff else { return }
        turningOff = true
        defer { turningOff = false }
        if let top = await editor?.scrollTopLine() { topLines[session.url.path] = top }
        guard await session.end(), self.session === session else { return }
        self.session = nil
        location = nil
        editor = nil
    }

    /// The viewer now shows `location` (another file, or none): Edit goes
    /// off, and the old file's text is saved.
    func shown(_ location: String?) {
        note = nil
        guard let session, location != self.location else { return }
        self.session = nil
        self.location = nil
        editor = nil
        Task { _ = await session.end() }
    }
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

/// The header's Edit toggle: a pencil, accent while on (as Focus is).
struct ViewerEditToggle: View {
    let on: Bool
    let editability: Editability
    let accent: Color
    let action: () -> Void

    var body: some View {
        let enabled = editability.canEdit || on
        Button(action: action) {
            Image(systemName: "pencil")
                .font(Theme.iconFont(ViewerHeader.iconSize, weight: ViewerHeader.iconWeight))
                .frame(width: ViewerHeader.glyphSide, height: ViewerHeader.glyphSide)
                .foregroundStyle(on ? accent : (enabled ? Theme.text2 : Theme.text3))
                .frame(width: 24, height: 24)
                .background(on ? accent.opacity(0.15) : Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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

/// "Editing · Saved", "Editing · Saving…", or "Not saved — <reason>" in
/// deny red with Retry (§2.2).
struct ViewerEditStatus: View {
    @ObservedObject var session: EditSession

    var body: some View {
        HStack(spacing: 6) {
            switch session.state {
            case .failed(let reason):
                Text(Self.words(for: session.state))
                    .scaledFont(12)
                    .foregroundStyle(Theme.deny)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tip(reason)
                Button("Retry") { Task { await session.saveNow() } }
                    .buttonStyle(.link)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.deny)
                    .fixedSize()
            default:
                Text(Self.words(for: session.state))
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func words(for state: EditSession.SaveState) -> String {
        switch state {
        case .saved: "Editing · Saved"
        case .saving: "Editing · Saving…"
        case .failed(let reason): "Not saved — \(reason)"
        case .paused: "Editing · Paused"
        }
    }
}
