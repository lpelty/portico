import AppKit
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
    /// How long to wait for the pane to be there and its page loaded:
    /// under the gateway's 10 s, so the agent hears why.
    var paneWait: Duration = .seconds(9)

    private struct WebPaneRef {
        weak var view: WKWebView?
        let load: WebPane.Load
    }

    private var web: WebPaneRef?
    private weak var paneView: NSView?
    /// The page token (`__porticoAgent.page`) of the last look: refs are
    /// only followed on the page that numbered them.
    private var lookedPage: String?
    private var actions = 0

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

    // MARK: perform

    func perform(_ act: ViewerAct) async -> ViewerResult {
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
        // The agent never drives a viewer the person can't see.
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
        let deadline = ContinuousClock.now + paneWait
        guard let view = await webView(showing: load, until: deadline) else { return fail(act, Message.timedOut) }
        await settle(view, until: deadline)
        await ensureScript(in: view)
        let target = act.args["target"]?.stringValue ?? ""
        switch act.action {
        case .look:
            return await look(act, shown: shown, in: view)
        case .click:
            return await click(act, target: target, in: view)
        case .type:
            return await type(act, target: target, in: view)
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
            await settle(view, until: ContinuousClock.now + paneWait)
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

    private func click(_ act: ViewerAct, target: String, in view: WKWebView) async -> ViewerResult {
        guard !target.isEmpty else { return fail(act, "Say what to click: a ref from the last look, or a button's or link's words.") }
        let page = lookedPage ?? ""
        guard await outline(target, page: page, field: false, in: view) else { return fail(act, Message.notFound) }
        let before = view.url
        let answer = await call(
            "return window.__porticoAgent.click(target, page)", ["target": target, "page": page], in: view) as? [String: Any]
        if answer?["notFound"] as? Bool == true { return fail(act, Message.notFound) }
        guard answer?["ok"] as? Bool == true else { return answered(act, answer, otherwise: "") }
        let label = (answer?["label"] as? String) ?? target
        return ViewerResult(id: act.id, ok: true, text: "Clicked \(label)." + (await navigated(view, from: before)))
    }

    private func type(_ act: ViewerAct, target: String, in view: WKWebView) async -> ViewerResult {
        guard !target.isEmpty else { return fail(act, "Say where to type: a ref from the last look, or a field's label.") }
        let text = act.args["text"]?.stringValue ?? ""
        let submit = act.args["submit"] == .bool(true)
        let page = lookedPage ?? ""
        guard await outline(target, page: page, field: true, in: view) else { return fail(act, Message.notFound) }
        let before = view.url
        let answer = await call(
            "return window.__porticoAgent.type(target, text, submit, page)",
            ["target": target, "text": text, "submit": submit, "page": page], in: view) as? [String: Any]
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
        try? await Task.sleep(for: highlightDuration)
        ring.removeFromSuperview()
        return true
    }

    /// " Now showing <title> — <location>." when the action navigated.
    private func navigated(_ view: WKWebView, from before: URL?) async -> String {
        try? await Task.sleep(for: .milliseconds(150))
        await settle(view, until: ContinuousClock.now + .seconds(5))
        guard view.url != before else { return "" }
        return " Now showing \(await location(of: view, shown: nil))."
    }

    /// "<title> — <path or URL>" for what the view shows now.
    private func location(of view: WKWebView, shown: ArtifactPresentation?) async -> String {
        let title = (view.title?.isEmpty == false ? view.title : nil) ?? shown?.title ?? ""
        let place: String
        if let url = view.url, url.isFileURL {
            place = url.path
        } else if view.url?.scheme == RenderedPageHandler.scheme, let file = shown?.fileURL {
            place = file.path
        } else {
            place = view.url?.absoluteString ?? shown?.artifact.location ?? ""
        }
        return title.isEmpty ? place : "\(title) — \(place)"
    }

    // MARK: web helpers

    private func webView(showing load: WebPane.Load, until deadline: ContinuousClock.Instant) async -> WKWebView? {
        while true {
            if let web, web.load == load, let view = web.view { return view }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Wait until the page has loaded (or the deadline).
    private func settle(_ view: WKWebView, until deadline: ContinuousClock.Instant) async {
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
    /// that (or by a view made without it) gets it now.
    private func ensureScript(in view: WKWebView) async {
        if await call("return typeof window.__porticoAgent === 'object'", in: view) as? Bool == true { return }
        guard let source = ViewerAgentScript.source else { return }
        _ = try? await view.evaluateJavaScript(source + "\n;true")
    }

    private func call(_ body: String, _ arguments: [String: Any] = [:], in view: WKWebView) async -> Any? {
        do {
            return try await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
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
        switch act.action {
        case .look:
            var text = "Open: \(shown.title) — \(shown.fileURL?.path ?? shown.artifact.location)\nThis is \(Message.article(kind)) \(kind)."
            if shown.media == .image, let file = shown.fileURL, let rep = NSImageRep(contentsOf: file) {
                text += " \(rep.pixelsWide) × \(rep.pixelsHigh) pixels."
            }
            // Let a pane that just slid open draw before it is captured.
            try? await Task.sleep(for: .milliseconds(100))
            let image = paneSnapshot().map { ViewerResult.Image(data: $0.base64EncodedString()) }
            return ViewerResult(id: act.id, ok: true, text: text, image: image)
        case .click, .type, .scroll:
            return fail(act, Message.notUsed(kind: kind))
        case .back:
            return fail(act, "There's nothing to go back to in the viewer.")
        }
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

// MARK: - The script

enum ViewerAgentScript {
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
