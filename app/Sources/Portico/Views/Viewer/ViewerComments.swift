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
              --pc-surface: \(token(.surface)); --pc-panel: \(token(.panel));
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

    static func isOn(_ path: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(path)
    }

    static func set(_ path: String, _ on: Bool, defaults: UserDefaults = .standard) {
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
    struct Draft: Equatable {
        var selection: CommentAnchoring.Selection?
        /// Edit mode: the selection's UTF-16 range in the buffer.
        var range: Range<Int>?
        var text: String = ""
    }

    @Published var shown = false
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

    func isAgent(_ author: String) -> Bool {
        author.compare(agentName, options: .caseInsensitive) == .orderedSame
    }

    /// The file the viewer shows changed (or none): comments as left for it, nothing active.
    func show(file url: URL?) {
        guard url != file else { reload(); return }
        file = url
        activeID = nil
        draft = nil
        error = nil
        shown = url.map { CommentsMemory.isOn($0.path, defaults: defaults) } ?? false
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
            "threads": threads.map { t -> [String: Any] in
                [
                    "id": t.id, "status": t.status.rawValue, "quote": t.quote, "orphan": t.isOrphan,
                    "replies": t.replies.map { r -> [String: Any] in
                        [
                            "author": r.author, "initial": Self.initial(r.author), "agent": isAgent(r.author),
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
        guard let evaluate,
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
    func attach(_ view: WKWebView) {
        webView = view
        evaluate = { [weak view] script in view?.evaluateJavaScript(script, completionHandler: nil) }
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

    /// The writing actions (Task 6 and 7); none in this build of the page.
    func handleAction(_ type: String, _ message: [String: Any], chat: Int, focus: CommentsFocus) {}
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
