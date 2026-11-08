import AppKit
import Foundation
import SwiftUI
import WebKit

// MARK: - CommentsTheme (v0.23)

/// The comment colours as CSS variables for the page and the editor: a
/// light `:root` block and a dark one under `prefers-color-scheme`, so the
/// page needs no appearance messages. Solid hex values only.
enum CommentsTheme {
    static let waitHex = ("#B86E00", "#F0B24A")
    static let waitSoftHex = ("#FFF3DE", "#3B2E16")
    static let accentHex = ("#3B6BE0", "#6B8FF2")
    static let accentSoftHex = ("#EBF0FC", "#26304A")
    /// Text on the bright `wait` highlight (an active anchor or a draft).
    static let onWaitHex = ("#FFFFFF", "#1C1C1E")

    static func css(accent: String? = nil) -> String {
        func block(_ pick: ((String, String)) -> String, _ token: (Theme.Token) -> String) -> String {
            """
              --pc-wait: \(pick(waitHex)); --pc-wait-soft: \(pick(waitSoftHex)); --pc-on-wait: \(pick(onWaitHex));
              --pc-accent: \(accent ?? pick(accentHex)); --pc-accent-soft: \(pick(accentSoftHex));
              --pc-agent: \(token(.agentAvatar)); --pc-card: \(token(.control)); --pc-border: \(token(.border));
              --pc-text: \(token(.text)); --pc-text2: \(token(.text2)); --pc-text3: \(token(.text3));
              --pc-surface: \(token(.surface)); --pc-panel: \(token(.panel)); --pc-danger: \(token(.dangerStrong));
            """
        }
        let light = block({ $0.0 }) { Theme.hex($0).light }
        let dark = block({ $0.1 }) { Theme.hex($0).dark }
        let cards = AppResources.url(forResource: "viewer-comments", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return ":root {\n\(light)\n}\n@media (prefers-color-scheme: dark) { :root {\n\(dark)\n} }\n" + cards
    }
}

// MARK: - CommentsMemory

/// Which files were last left with comments shown, by path (user defaults
/// `viewer.commentsShown`; a path is listed only while on). A file opens
/// with comments off unless it was left on.
enum CommentsMemory {
    static let key = "viewer.commentsShown"
    /// v0.23 §13.2: files whose margin shows resolved threads.
    static let resolvedKey = "viewer.commentsShowResolved"

    static func isOn(_ path: String, key: String = key, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(path)
    }

    static func set(_ path: String, _ on: Bool, key: String = key, defaults: UserDefaults = .standard) {
        var paths = (defaults.stringArray(forKey: key) ?? []).filter { $0 != path }
        if on { paths.append(path) }
        defaults.set(paths, forKey: key)
    }
}

// MARK: - CommentTime

/// A comment's time as a card shows it: "just now", "40 min ago", "2 h
/// ago", then the date ("Nov 4", with the year when it isn't this year).
enum CommentTime {
    static func date(_ at: String?) -> Date? {
        guard let at else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: at) { return d }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: at) { return d }
        return nil
    }

    static func relative(
        _ at: String?, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let at else { return "" }
        let style = { (d: Date) -> String in
            var cal = calendar
            cal.locale = locale
            let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
            let f = DateFormatter()
            f.calendar = cal
            f.locale = locale
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
            return f.string(from: d)
        }
        if let d = date(at) {
            let seconds = now.timeIntervalSince(d)
            if seconds < 60 { return "just now" }
            if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
            if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
            return style(d)
        }
        // A date only ("2026-10-17", as some files have it).
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        if at.count == 10, let d = day.date(from: at) { return style(d) }
        return ""
    }
}

// MARK: - ViewerComments

/// The editor's buffer, in Edit mode: comment actions are changes to it,
/// saved by the editor's usual path; the file underneath is never written.
@MainActor
protocol CommentsBuffer: AnyObject {
    /// The editor's text in its own LF space (a CRLF file's breaks count as one);
    /// the save path writes the file's line endings.
    func currentText() async -> String?
    /// The draft's range in that space, mapped through edits since Comment was chosen.
    func draftRange() async -> Range<Int>?
    func applyChange(from: Int, to: Int, insert: String, expectedLength: Int) async -> Bool
}

/// The app's half of focusing the viewer, for turning comments on.
@MainActor
protocol CommentsFocus: AnyObject {
    func isFocused(chat: Int) -> Bool
    func toggleFocus(chat: Int)
}

extension AppModel: CommentsFocus {}

/// The viewer's comments: whether the margin is shown for the file, which
/// card is active, the draft, and the page's messages. Swift owns the state
/// and pushes it to the page (`__porticoComments.render`); the page draws
/// it and posts the person's actions back.
@MainActor
final class ViewerComments: ObservableObject {
    static let staleWords = "Not saved — the text you chose changed; select it again and choose Comment."
    static let notUTF8Words = "This file isn't UTF-8 text; comments can't be added."
    static let changedWords = "This comment changed since you opened it; try again."

    struct Draft: Equatable {
        var selection: CommentAnchoring.Selection?
        /// Reading mode: where the selection was in the file, and its text then.
        var anchor: Range<Int>?
        var quote: String?
        /// Edit mode: the selection's UTF-16 range in the buffer.
        var range: Range<Int>?
        var text: String = ""
    }

    @Published var shown = false
    /// A field in the margin has the keyboard (Edit mode's Esc leaves it alone then).
    var marginFocused = false
    /// Resolved threads are hidden unless this is on (remembered per file).
    @Published var showResolved = false
    @Published var activeID: String?
    @Published var draft: Draft?
    @Published var error: String?
    @Published private(set) var threads: [CommentFormat.Thread] = []
    @Published private(set) var file: URL?
    /// Why comments can't be added, replied to or resolved (a read-only file); nil when they can.
    @Published var readOnly: String?

    /// The chat whose viewer this is, and what widens it (set by `ViewerView`).
    var chat = 0
    weak var focus: (any CommentsFocus)?

    var helloPersonName: String?
    var agentName = "Agent"
    var accentHex: String?

    /// The page that shows the margin (the rendered page or the editor's).
    weak var webView: AnyObject?
    var evaluate: ((String) -> Void)?
    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The person's name on their comments: the hello's, else the computer's full user name.
    var personName: String {
        if let name = helloPersonName, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    /// Open threads, orphans included (spec §12.4).
    var openCount: Int { threads.filter { $0.status == .open }.count }

    /// The person's own comments (by the name in use), which they may edit.
    func isPerson(_ author: String) -> Bool {
        Self.sameAuthor(author, personName)
    }

    func isAgent(_ author: String) -> Bool {
        Self.sameAuthor(author, agentName)
    }

    /// A reply line writes a name's colons as RATIO (#11): both sides are compared as written.
    static func sameAuthor(_ a: String, _ b: String) -> Bool {
        CommentFormat.replyAuthor(a).compare(CommentFormat.replyAuthor(b), options: .caseInsensitive) == .orderedSame
    }

    /// The file the viewer shows changed (or none): comments as left for it, nothing active.
    func show(file url: URL?) {
        guard url != file else { reload(); return }
        file = url
        activeID = nil
        draft = nil
        error = nil
        shown = url.map { CommentsMemory.isOn($0.path, defaults: defaults) } ?? false
        showResolved = url.map { CommentsMemory.isOn($0.path, key: CommentsMemory.resolvedKey, defaults: defaults) } ?? false
        reload()
    }

    /// Re-read the file's comments.
    func reload(text: String? = nil) {
        guard let file else { threads = []; return }
        let source = text ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        threads = CommentFormat.parse(source).threads
        if let id = activeID, !threads.contains(where: { $0.id == id }) { activeID = nil }
    }

    /// Show or hide the margin. On widens the viewer when it isn't; off never narrows it.
    func setShown(_ on: Bool, chat: Int, focus: CommentsFocus) {
        shown = on
        if let file { CommentsMemory.set(file.path, on, defaults: defaults) }
        if on, !focus.isFocused(chat: chat) { focus.toggleFocus(chat: chat) }
        if !on { draft = nil; activeID = nil; evaluate?("window.__porticoComments && __porticoComments.clearDraft()") }
        push()
    }

    // MARK: the page

    func pageState(now: Date = Date()) -> [String: Any] {
        var theme: [String: String] = [:]
        if let accentHex { theme["--pc-accent"] = accentHex }
        return [
            "on": shown,
            "activeID": activeID as Any? ?? NSNull(),
            "readOnly": readOnly as Any? ?? NSNull(),
            "draft": draft.map { ["author": personName, "initial": Self.initial(personName), "text": $0.text] as [String: Any] }
                as Any? ?? NSNull(),
            "error": error as Any? ?? NSNull(),
            "theme": theme,
            "showResolved": showResolved,
            "resolvedCount": threads.filter { $0.status == .resolved }.count,
            "threads": threads.map { t -> [String: Any] in
                [
                    "id": t.id, "status": t.status.rawValue, "quote": t.quote, "orphan": t.isOrphan,
                    "replies": t.replies.enumerated().map { index, r -> [String: Any] in
                        [
                            "author": r.author, "initial": Self.initial(r.author), "agent": isAgent(r.author),
                            "own": isPerson(r.author), "index": index, "at": r.at as Any? ?? NSNull(),
                            "time": CommentTime.relative(r.at, now: now), "text": r.text,
                        ]
                    },
                ]
            },
        ]
    }

    static func initial(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    /// Send the state to the page.
    func push() {
        guard !away, let evaluate,
            let data = try? JSONSerialization.data(withJSONObject: pageState()),
            let json = String(data: data, encoding: .utf8)
        else { return }
        evaluate("window.__porticoComments && __porticoComments.render(\(json))")
        scheduleTimes()
    }

    /// Times re-render every 60 s while comments are shown.
    private func scheduleTimes() {
        timer?.invalidate()
        timer = nil
        guard shown else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
    }

    /// The page that posted, so the state can be pushed back to it.
    /// `world`: where the page's comments script runs (v0.24: the viewer's
    /// in `ViewerCommentsScript.world`; the editor's in its page).
    func attach(_ view: WKWebView, world: WKContentWorld = .page) {
        // A page that posted is a page comments are for (the handler checked
        // it), so whatever "away" said of an earlier page no longer holds.
        if webView !== view { away = false }
        webView = view
        scriptWorld = world
        evaluate = { [weak view] script in view?.evaluateJavaScript(script, in: nil, in: world, completionHandler: nil) }
        installShortcut()
    }

    /// Review round 2 (R4): the pane has left the rendered page (a linked
    /// file, a site, the failure page). While away, no threads are pushed and
    /// the comments script there leaves the page's context menu alone;
    /// coming back resumes and pushes the state again.
    private(set) var away = false

    func setAway(_ away: Bool) {
        guard away != self.away else { return }
        self.away = away
        if away {
            evaluate?("window.__porticoComments && (window.__porticoComments.ownMenu = false)")
        } else {
            push()
        }
    }

    /// The content world the attached page's comments script runs in.
    private(set) var scriptWorld: WKContentWorld = .page

    // MARK: ⌥⌘M (spec §13.2)

    nonisolated(unsafe) private var shortcutMonitor: Any?

    deinit {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
    }

    /// ⌥⌘M with the page or the editor in front adds a comment on the selection,
    /// by the same rules as the menu's Comment (a beep when it can't).
    private func installShortcut() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags
            guard CommentShortcut.matches(
                characters: event.charactersIgnoringModifiers, option: flags.contains(.option),
                command: flags.contains(.command), shift: flags.contains(.shift), control: flags.contains(.control)),
                let self, let view = self.webView as? WKWebView, let window = view.window, event.window === window,
                let responder = window.firstResponder as? NSView, responder === view || responder.isDescendant(of: view)
            else { return event }
            self.commentFromShortcut(in: view)
            return nil
        }
    }

    func commentFromShortcut(in view: WKWebView) {
        let editing = editBuffer != nil
        let script = editing
            ? "var s = portico.selectionRange(); return {from: s.from, to: s.to, refusal: s.refusal};"
            : "return window.__porticoComments ? window.__porticoComments.selectionInfo() : null;"
        Task { @MainActor [weak self] in
            guard let self, let focus = self.focus else { return }
            let value = try? await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: editing ? .page : self.scriptWorld)
            let info = value as? [String: Any]
            if editing {
                let from = (info?["from"] as? NSNumber)?.intValue ?? 0, to = (info?["to"] as? NSNumber)?.intValue ?? 0
                var sel: [String: Any]? = nil
                if to > from {
                    sel = ["text": "selection", "lines": [0, 0], "occurrence": 0]
                    if let r = info?["refusal"] as? String { sel?["refusal"] = r }
                }
                let context = self.menuContext(selection: sel, editMode: true, trustSelection: true)
                guard context.hasSelection, context.readOnly == nil, context.refusal == nil else { NSSound.beep(); return }
                self.beginDraft(nil, range: from..<to, chat: self.chat, focus: focus)
            } else {
                let context = self.menuContext(selection: info, editMode: false)
                guard context.hasSelection, context.readOnly == nil, context.refusal == nil,
                    let info, let selection = Self.selection(info)
                else { NSSound.beep(); return }
                self.beginDraft(selection, chat: self.chat, focus: focus)
            }
        }
    }

    /// A message from the page, for this controller's chat.
    func received(_ body: Any) {
        guard let focus else { return }
        received(body, chat: chat, focus: focus)
    }

    /// A message from the page's `comments` handler.
    func received(_ body: Any, chat: Int, focus: CommentsFocus) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        let id = message["id"] as? String
        switch type {
        case "ready":
            reload(text: message["text"] as? String)
            push()
        case "activate":
            activeID = id
            error = nil
            push()
        case "anchorClicked":
            activeID = id
            if !shown { setShown(true, chat: chat, focus: focus) } else { push() }
        default:
            handleAction(type, message, chat: chat, focus: focus)
        }
    }

    /// Edit mode's buffer, while the editor shows the file.
    weak var editBuffer: (any CommentsBuffer)?

    /// A draft made in the other mode (Edit turned on or off since) can't be posted where it was.
    static let lostPlaceText = "Select the text again to post this comment."

    /// Apply a comment action to the editor's buffer as one change; if the
    /// buffer moved under it, fetch the text again and retry once.
    @discardableResult
    func applyInBuffer(_ op: CommentWriter.Op, made: CommentWriter.Made? = nil) async -> Bool {
        guard let buffer = editBuffer else { return false }
        if let readOnly {
            error = readOnly
            return false
        }
        var op = op
        if case .addRange(_, let body) = op, let mapped = await buffer.draftRange() { op = .addRange(mapped, body: body) }
        let edit = CommentWriter.edit(for: op, author: personName, now: Date(), made: made)
        for _ in 0..<2 {
            guard let old = await buffer.currentText() else { break }
            let new: String
            do {
                new = try edit(old)
            } catch let refusal as CommentFormat.Refusal {
                error = "Not saved — \(CommentAnchoring.reason(refusal))"
                return false
            } catch CommentFormat.EditError.changed {
                error = Self.changedWords
                reload(text: old)
                return false
            } catch {
                self.error = "Not saved — the comment's thread is gone"
                return false
            }
            let splice = TextSplice.minimal(old, new)
            if await buffer.applyChange(from: splice.from, to: splice.to, insert: splice.insert, expectedLength: old.utf16.count) {
                reload(text: new)
                return true
            }
        }
        error = "Not saved — the text changed while the comment was being added; try again"
        return false
    }

    /// Told after a comment action wrote the file (reading mode): the app
    /// tells the gateway (`files.edited`) and the pane re-reads in place.
    var onWritten: ((URL) -> Void)?
    /// Bumped by each write, so the page re-reads keeping its scroll.
    @Published private(set) var paneRevision: String?
    private var writes = 0
    private var keptKey: String?
    private var writtenStamp: String?

    /// The key the viewer's pane is identified by: the file's identity,
    /// except that this controller's own writes keep the old key (the pane
    /// re-reads in place through `paneRevision`, keeping the reader's place).
    func paneKey(_ identity: String) -> String {
        if let stamp = writtenStamp, identity.hasSuffix(stamp), let keptKey { return keptKey }
        writtenStamp = nil
        keptKey = identity
        return identity
    }

    static func diskStamp(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = (a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        return "|\(date)|\(size)"
    }

    // MARK: writing

    func handleAction(_ type: String, _ message: [String: Any], chat: Int, focus: CommentsFocus) {
        let id = message["id"] as? String
        let text = message["text"] as? String ?? ""
        switch type {
        case "post":
            guard var d = draft else { return }
            d.text = text
            draft = d
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let made = CommentWriter.Made()
            let op: CommentWriter.Op
            if editBuffer != nil, let range = d.range {
                op = .addRange(range, body: text)
            } else if editBuffer == nil, let anchor = d.anchor, let quote = d.quote {
                op = .addAt(anchor, quote: quote, body: text)
            } else if editBuffer == nil, let s = d.selection {
                op = .add(s, body: text)
            } else {
                // Sweep #12 (ruling 24): Edit went on or off since the draft was made, so its
                // place is in the other form. The text stays; nothing is written.
                error = Self.lostPlaceText
                push()
                return
            }
            perform(op, made: made) { [weak self] ok in
                guard let self, ok else { return }
                self.draft = nil
                self.activeID = made.id
                self.error = nil
                self.evaluate?("window.__porticoComments && __porticoComments.clearDraft()")
            }
        case "cancelDraft":
            draft = nil
            error = nil
            evaluate?("window.__porticoComments && __porticoComments.clearDraft()")
            push()
        case "reply":
            guard let id, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            perform(.reply(id: id, body: text)) { [weak self] ok in if ok { self?.error = nil } }
        case "resolve", "reopen":
            guard let id else { return }
            perform(.setStatus(id: id, resolved: type == "resolve")) { [weak self] ok in
                guard let self, ok else { return }
                self.error = nil
                if type == "resolve", self.activeID == id { self.activeID = nil }
            }
        case "edit":
            guard let id, let index = (message["index"] as? NSNumber)?.intValue,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            perform(.edit(id: id, index: index, body: text, fingerprint: Self.fingerprint(message["fp"]))) { [weak self] ok in
                if ok { self?.error = nil }
            }
        case "delete":
            guard let id, let index = (message["index"] as? NSNumber)?.intValue else { return }
            perform(.delete(id: id, index: index, fingerprint: Self.fingerprint(message["fp"]))) { [weak self] ok in
                guard let self, ok else { return }
                self.error = nil
                if index == 0, self.activeID == id { self.activeID = nil }
            }
        case "marginFocus":
            marginFocused = (message["on"] as? Bool) ?? false
        case "showResolved":
            showResolved = (message["on"] as? Bool) ?? false
            if let file { CommentsMemory.set(file.path, showResolved, key: CommentsMemory.resolvedKey, defaults: defaults) }
            push()
        case "commentMenu":
            let from = (message["from"] as? NSNumber)?.intValue ?? 0
            let to = (message["to"] as? NSNumber)?.intValue ?? 0
            let x = (message["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (message["y"] as? NSNumber)?.doubleValue ?? 0
            var info: [String: Any]? = nil
            if to > from {
                info = ["text": "selection", "lines": [0, 0], "occurrence": 0]
                if let refusal = message["refusal"] as? String { info?["refusal"] = refusal }
            }
            showMenu(selection: info, at: CGPoint(x: x, y: y), editMode: true, chat: chat, focus: focus,
                     trustSelection: true) { [weak self] in
                self?.beginDraft(nil, range: from..<to, chat: chat, focus: focus)
            }
        case "menu":
            let selection = message["selection"] as? [String: Any]
            let x = (message["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (message["y"] as? NSNumber)?.doubleValue ?? 0
            showMenu(selection: selection, at: CGPoint(x: x, y: y), editMode: false, chat: chat, focus: focus)
        default:
            break
        }
    }

    /// A comment action: through the editor's buffer in Edit mode, else written to the file.
    private func perform(_ op: CommentWriter.Op, made: CommentWriter.Made? = nil, then: @escaping (Bool) -> Void) {
        if editBuffer != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ok = await self.applyInBuffer(op, made: made)
                then(ok)
                self.push()
            }
        } else {
            then(write(op, made: made))
            push()
        }
    }

    static func fingerprint(_ value: Any?) -> CommentFormat.Fingerprint? {
        guard let f = value as? [String: Any], let author = f["author"] as? String, let text = f["text"] as? String else { return nil }
        return .init(author: author, at: f["at"] as? String, text: text)
    }

    /// Write one comment action to the file; false (and `error` set) when it couldn't.
    @discardableResult
    func write(_ op: CommentWriter.Op, made: CommentWriter.Made? = nil) -> Bool {
        guard let file else { return false }
        if let readOnly {
            error = readOnly
            return false
        }
        do {
            try CommentWriter.apply(CommentWriter.edit(for: op, author: personName, now: Date(), made: made), to: file)
        } catch FileEditing.Failure.notText {
            error = Self.notUTF8Words
            return false
        } catch let failure as FileEditing.Failure {
            error = "Not saved — \(failure.description)"
            return false
        } catch is CommentWriter.Stale {
            error = Self.staleWords
            return false
        } catch CommentFormat.EditError.changed {
            error = Self.changedWords
            reload()
            return false
        } catch let refusal as CommentFormat.Refusal {
            error = "Not saved — \(CommentAnchoring.reason(refusal))"
            return false
        } catch {
            self.error = "Not saved — the comment's thread is gone"
            return false
        }
        reload()
        writes += 1
        writtenStamp = Self.diskStamp(file)
        paneRevision = "comments-\(writes)"
        onWritten?(file)
        return true
    }

    // MARK: the menu and the draft

    /// What the menu shows for the page's selection (`selectionInfo()`, or nil for none).
    func menuContext(selection: [String: Any]?, editMode: Bool, trustSelection: Bool = false) -> CommentMenu.Context {
        guard let selection, let text = selection["text"] as? String, !text.isEmpty else {
            return .init(editMode: editMode, hasSelection: false, readOnly: readOnly, refusal: nil)
        }
        var refusal: String?
        switch selection["refusal"] as? String {
        case "ignored": refusal = CommentAnchoring.reason(.insideIgnored)
        case "atom": refusal = CommentAnchoring.reason(.insideAtom)
        case "cell": refusal = CommentAnchoring.cellWords
        case "widget": refusal = CommentAnchoring.tableWidgetWords
        case .some: refusal = CommentAnchoring.reason(.crossesBlocks)
        case nil:
            if trustSelection {
                refusal = nil
            } else if let sel = Self.selection(selection), let file,
                let source = try? String(contentsOf: file, encoding: .utf8)
            {
                if case .failure(let r) = CommentAnchoring.locate(sel, in: source) { refusal = CommentAnchoring.reason(r) }
            } else {
                refusal = CommentAnchoring.reason(.crossesBlocks)
            }
        }
        return .init(editMode: editMode, hasSelection: true, readOnly: readOnly, refusal: refusal)
    }

    static func selection(_ info: [String: Any]) -> CommentAnchoring.Selection? {
        guard let text = info["text"] as? String, let lines = info["lines"] as? [NSNumber], lines.count == 2 else {
            return nil
        }
        let a = lines[0].intValue, b = lines[1].intValue
        guard a <= b else { return nil }
        return .init(text: text, lines: a...b, occurrence: (info["occurrence"] as? NSNumber)?.intValue ?? 0,
                     cell: (info["cell"] as? NSNumber)?.intValue, row: (info["row"] as? NSNumber)?.intValue ?? 0,
                     table: (info["table"] as? NSNumber)?.intValue ?? 0)
    }

    /// Choose Comment: comments on (widening if needed), a draft card at the
    /// selection, the selected text in the active highlight.
    func beginDraft(_ selection: CommentAnchoring.Selection?, range: Range<Int>? = nil, chat: Int, focus: CommentsFocus) {
        var d = Draft(selection: selection, range: range)
        if let selection, range == nil, let file, let source = try? String(contentsOf: file, encoding: .utf8),
            case .success(let found) = CommentAnchoring.locate(selection, in: source)
        {
            d.anchor = found
            d.quote = CommentFormat.quoteText(String(decoding: Array(source.utf16)[found], as: UTF16.self))
        }
        draft = d
        activeID = nil
        error = nil
        evaluate?("window.__porticoComments && __porticoComments.markDraft()")
        if !shown { setShown(true, chat: chat, focus: focus) } else { push() }
    }

    private var menuTargets: [MenuAction] = []

    /// The viewer's own context menu at the page point.
    func showMenu(selection: [String: Any]?, at point: CGPoint, editMode: Bool, chat: Int, focus: CommentsFocus,
                  trustSelection: Bool = false, comment: (() -> Void)? = nil) {
        guard let view = webView as? NSView else { return }
        let context = menuContext(selection: selection, editMode: editMode, trustSelection: trustSelection)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuTargets = []
        for item in CommentMenu.items(context) {
            if item.isDivider { menu.addItem(.separator()); continue }
            let action: () -> Void
            switch item.title {
            case "Comment":
                action = { [weak self] in
                    if let comment { comment(); return }
                    guard let self, let selection, let sel = Self.selection(selection) else { return }
                    self.beginDraft(sel, chat: chat, focus: focus)
                }
            case "Cut": action = { [weak view] in NSApp.sendAction(#selector(NSText.cut(_:)), to: view, from: nil) }
            case "Copy": action = { [weak view] in NSApp.sendAction(#selector(NSText.copy(_:)), to: view, from: nil) }
            case "Paste": action = { [weak view] in NSApp.sendAction(#selector(NSText.paste(_:)), to: view, from: nil) }
            default: action = { [weak view] in NSApp.sendAction(#selector(NSText.selectAll(_:)), to: view, from: nil) }
            }
            let target = MenuAction(action)
            menuTargets.append(target)
            let entry = NSMenuItem(title: item.title, action: #selector(MenuAction.fire(_:)), keyEquivalent: item.key ?? "")
            if item.option { entry.keyEquivalentModifierMask = [.command, .option] }
            entry.target = target
            entry.isEnabled = item.enabled
            entry.toolTip = item.tip
            if let symbol = item.symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        let flipped = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        menu.popUp(positioning: nil, at: flipped, in: view)
    }
}

/// A menu item's action, held while the menu is up.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

// MARK: - ViewerCommentsToggle

/// The Show comments toggle in the viewer header, just left of Edit: a
/// speech bubble; off, the count of open threads in amber beside it; on,
/// the accent outline and the solid accent-soft fill.
struct ViewerCommentsToggle: View {
    let on: Bool
    let count: Int
    let focused: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "bubble.left")
                    .font(Theme.iconFont(ViewerHeader.iconSize, weight: ViewerHeader.iconWeight))
                    .frame(width: ViewerHeader.glyphSide, height: ViewerHeader.glyphSide)
                if !on, count > 0 {
                    Text("\(count)")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(Theme.wait)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(on ? accent : Theme.text2)
            .padding(.horizontal, !on && count > 0 ? 6 : 0)
            .frame(minWidth: ViewerHeader.buttonHeight, minHeight: ViewerHeader.buttonHeight)
            .background(on ? Theme.accentSoft : Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(on ? accent : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .tip(Self.tip(on: on, focused: focused))
        .accessibilityLabel(on ? "Hide comments" : (count > 0 ? "Show comments, \(count) open" : "Show comments"))
    }

    static func tip(on: Bool, focused: Bool) -> String {
        if on { return "Hide comments" }
        return focused ? "Show comments" : "Show comments: widens the viewer"
    }

    /// Only for a Markdown file shown in the file viewer (not a space).
    static func shows(media: Media, isSpace: Bool) -> Bool {
        media == .markdown && !isSpace
    }
}

// MARK: - environment

private struct ViewerCommentsKey: EnvironmentKey {
    static let defaultValue: ViewerComments? = nil
}

extension EnvironmentValues {
    /// The file viewer's comments controller (v0.23); the page and the editor post to it.
    var viewerComments: ViewerComments? {
        get { self[ViewerCommentsKey.self] }
        set { self[ViewerCommentsKey.self] = newValue }
    }
}
