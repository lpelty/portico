import AppKit
import SwiftUI

// MARK: - Prose runs

/// A message's blocks, with each stretch of plain prose (paragraphs, heads
/// and lists with nothing under their items) gathered into one run, drawn
/// as one text view so a selection crosses paragraphs and list items. Code,
/// quotes, tables and rules stay blocks of their own.
enum MarkdownRun: Equatable {
    case prose([MarkdownBlock], first: Bool)
    case block(MarkdownBlock, first: Bool)

    static func split(_ blocks: [MarkdownBlock]) -> [MarkdownRun] {
        var runs: [MarkdownRun] = []
        var prose: [MarkdownBlock] = []
        var proseStart = 0
        for (index, block) in blocks.enumerated() {
            if isProse(block) {
                if prose.isEmpty { proseStart = index }
                prose.append(block)
            } else {
                if !prose.isEmpty { runs.append(.prose(prose, first: proseStart == 0)) }
                prose = []
                runs.append(.block(block, first: index == 0))
            }
        }
        if !prose.isEmpty { runs.append(.prose(prose, first: proseStart == 0)) }
        return runs
    }

    static func isProse(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph, .heading: true
        case .list(let items): items.allSatisfy { $0.blocks.isEmpty }
        default: false
        }
    }
}

// MARK: - Attributed text

/// Prose blocks as AppKit attributed text, laid out like the SwiftUI
/// blocks they replace: body 13 with 5 of line spacing, 10 between blocks,
/// 6 between list items, heads semibold a little larger.
@MainActor
enum MarkdownAttributed {
    static let bodySize = MarkdownText.bodySize
    static let lineSpacing = MarkdownText.lineSpacing
    /// Where an outer list item's text starts, and how much a nested one adds.
    static let listIndent: CGFloat = 24
    static let nestedIndent: CGFloat = 26

    static func prose(_ blocks: [MarkdownBlock], first: Bool = true, spacing: CGFloat = 10, secondary: Bool = false) -> NSAttributedString {
        let color = NSColor(secondary ? Theme.text2 : Theme.text)
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            let after: CGFloat = last ? 0 : spacing
            switch block {
            case .paragraph(let text):
                appendParagraph(inline(text, color: color), to: out, style: style(after: after), last: last)
            case .heading(let level, let text):
                let size = bodySize + (level == 1 ? 3 : level == 2 ? 2 : 1)
                let head = inline(text, font: .systemFont(ofSize: size, weight: .semibold), color: color)
                let before: CGFloat = (index == 0 && first) ? 0 : 4
                appendParagraph(head, to: out, style: style(before: before, after: after), last: last)
            case .list(let items):
                for (itemIndex, item) in items.enumerated() {
                    let lastItem = itemIndex == items.count - 1
                    let start = listIndent + (item.level == 0 ? 0 : nestedIndent)
                    let marker = item.number ?? (item.level == 0 ? "•" : "◦")
                    let line = NSMutableAttributedString(
                        string: marker + "\t",
                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular),
                                     .foregroundColor: NSColor(Theme.text3)])
                    line.append(inline(item.text, color: color))
                    let paragraph = style(after: lastItem ? after : 6)
                    paragraph.firstLineHeadIndent = start - 18
                    paragraph.headIndent = start
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: start)]
                    appendParagraph(line, to: out, style: paragraph, last: last && lastItem)
                }
            default:
                break
            }
        }
        return out
    }

    /// One block's inline Markdown: bold, italic, `code` (monospaced on
    /// the surface colour), strikethrough, links. A line break inside the
    /// block stays a line break, not a new paragraph.
    static func inline(_ text: String, font: NSFont = .systemFont(ofSize: bodySize), color: NSColor) -> NSMutableAttributedString {
        let parsed = MarkdownParser.inline(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let string = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) : font
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits))
                runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if intent.contains(.code) { attributes[.backgroundColor] = NSColor(Theme.surface) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        return out
    }

    /// A code block's text: monospaced 12, 3 of line spacing, as fenced.
    static func code(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(Theme.text),
            .paragraphStyle: style,
        ])
    }

    private static func style(before: CGFloat = 0, after: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return style
    }

    private static func appendParagraph(_ text: NSMutableAttributedString, to out: NSMutableAttributedString, style: NSParagraphStyle, last: Bool) {
        if !last { text.append(NSAttributedString(string: "\n", attributes: text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:])) }
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        out.append(text)
    }
}

// MARK: - The view

/// Read-only text the way Mail and Notes do it: a drag selects from
/// anywhere in the text's area (not only on a letter), across paragraphs
/// and list items; the I-beam shows it can be selected; ⌘C and the
/// context menu copy; links open in the default browser.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    /// False for code: lines keep their length and the view is as wide as
    /// the longest (its scroll view scrolls sideways).
    var wraps = true

    func makeNSView(context: Context) -> NSTextView {
        let view = SelectableTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = wraps
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor(Theme.accent), .cursor: NSCursor.pointingHand]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.textStorage?.setAttributedString(text)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.isEqual(to: text) == false {
            view.textStorage?.setAttributedString(text)
        }
    }

    /// As wide as offered; as tall as the text laid out at that width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        container.containerSize = NSSize(width: wraps ? offered : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: wraps ? offered : ceil(used.width) + 1, height: ceil(used.height))
    }
}

// MARK: - Click elsewhere deselects

/// The text view `SelectableText` draws. Each message is its own
/// `NSTextView`, and AppKit keeps a text view's selection when the click
/// goes somewhere else (it only dims it), so a selection in one message
/// stayed after a click on another message, the transcript, the sidebar or
/// the composer. Everywhere else on macOS that click clears it (v0.5
/// decision 5).
///
/// How: every one of these views registers itself (weakly), and one local
/// monitor sees each left mouse-down in the app before the click is
/// delivered. It finds the view under the click and collapses the selection
/// of every registered view in that window that the click is not inside.
/// The event goes on unchanged, so a click or drag inside a message
/// (including starting a new selection in another one) works as before, and
/// ⌘C copies whatever is still selected. Clicks in other windows (menus,
/// popovers, the About panel) leave the selection alone, as AppKit does.
final class SelectableTextView: NSTextView {
    private static let all = NSHashTable<SelectableTextView>.weakObjects()
    private static var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Self.all.add(self)
        Self.installMonitor()
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        // Local monitors run on the main thread, before the event is sent on.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if let window = event.window, let content = window.contentView {
                    let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                    deselect(in: window, except: content.hitTest(point))
                }
            }
            return event
        }
    }

    /// Collapse the selection of every registered view in `window` that
    /// `hit` (the view under a click, nil for none) is not inside.
    static func deselect(in window: NSWindow, except hit: NSView?) {
        for view in all.allObjects where view.window === window && view.selectedRange().length > 0 {
            if let hit, hit === view || hit.isDescendant(of: view) { continue }
            view.setSelectedRange(NSRange(location: view.selectedRange().location, length: 0))
        }
    }
}
