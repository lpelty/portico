import AppKit
import Foundation

/// v0.26.1 field diagnostic for jumpy scrolling: off unless the file
/// `scroll-trace` exists in the app's home (the folder the gateway's state
/// lives in), then one line per scroll reading and per move the app makes
/// itself, with why, appended to `scroll-trace.log` there.
/// No message text is written, only ids, offsets and reasons.
///
/// 0.43.3 adds, for the transcript that sticks and the one that goes blank
/// until scrolled: each row laid out, dropped, or changing height (`row`),
/// the transcript's width (`width`), what the viewer shows (`viewer`), and
/// twice a second what is actually on screen (`paint`), each only when it
/// changes.
@MainActor
enum ScrollTrace {
    private static let directory = GatewaySupervisor.resolveHome().url
    static var enabled = FileManager.default.fileExists(atPath: directory.appendingPathComponent("scroll-trace").path)
    /// Tests read the lines here instead of the file.
    static var sink: ((String) -> Void)?
    private static let start = Date()
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let url = directory.appendingPathComponent("scroll-trace.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    static func note(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let text = "\(ms) \(line())\n"
        if let sink { sink(text); return }
        handle?.write(Data(text.utf8))
    }

    /// A row's frame changed from `old` (nil: not laid out until now): the
    /// line to write, or nil when only its place moved (every scroll does that).
    nonisolated static func rowLine(chat: Int, id: String, old: CGRect?, new: CGRect) -> String? {
        guard let old else { return "row chat=\(chat) in id=\(id) h=\(Int(new.height)) y=\(Int(new.minY))" }
        guard abs(old.height - new.height) >= 1 else { return nil }
        return "row chat=\(chat) height id=\(id) from=\(Int(old.height)) to=\(Int(new.height)) y=\(Int(new.minY))"
    }

    nonisolated static func rowGoneLine(chat: Int, id: String) -> String {
        "row chat=\(chat) out id=\(id)"
    }

    /// What is on screen, in counts (no text): the rows the layout says are
    /// in view, and the text views actually inside the visible area, with
    /// those of them that could draw nothing.
    struct Paint: Equatable {
        var rowsInView = 0
        var textViews = 0
        var zeroHeight = 0
        var hidden = 0
        var empty = 0
        var unlaid = 0
        /// Text views in view waiting to be drawn again.
        var pending = 0
        var documentHeight = 0
        var clipTop = 0
        var clipHeight = 0
        var phase = "idle"

        func line(chat: Int) -> String {
            "paint chat=\(chat) rowsInView=\(rowsInView) textViews=\(textViews) zeroHeight=\(zeroHeight) "
                + "hidden=\(hidden) empty=\(empty) unlaid=\(unlaid) pending=\(pending) doc=\(documentHeight) clipTop=\(clipTop) "
                + "clipHeight=\(clipHeight) phase=\(phase)"
        }
    }

    /// Reads `Paint` from the transcript's scroll view: `rowFrames` are in
    /// the scroll view's own space (its visible area at the origin).
    static func paint(scroll: NSScrollView, rowFrames: [CGRect], phase: String) -> Paint? {
        guard let document = scroll.documentView else { return nil }
        let clip = scroll.contentView.bounds
        let visible = CGRect(x: 0, y: 0, width: clip.width, height: clip.height)
        var paint = Paint()
        paint.rowsInView = rowFrames.filter { $0.intersects(visible) }.count
        paint.documentHeight = Int(document.frame.height)
        paint.clipTop = Int(clip.minY)
        paint.clipHeight = Int(clip.height)
        paint.phase = phase
        var stack: [NSView] = [document]
        while let view = stack.popLast() {
            if let text = view as? NSTextView {
                let inClip = text.convert(text.bounds, to: scroll.contentView)
                guard inClip.intersects(clip) || (text.bounds.height < 1 && clip.contains(inClip.origin)) else { continue }
                paint.textViews += 1
                if text.bounds.height < 1 || text.bounds.width < 1 { paint.zeroHeight += 1 }
                if text.isHiddenOrHasHiddenAncestor || text.alphaValue < 0.01 { paint.hidden += 1 }
                if (text.textStorage?.length ?? 0) == 0 { paint.empty += 1 }
                if text.needsDisplay { paint.pending += 1 }
                if let layout = text.layoutManager, let container = text.textContainer,
                   (text.textStorage?.length ?? 0) > 0,
                   layout.usedRect(for: container).height < 1 {
                    paint.unlaid += 1
                }
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        return paint
    }
}
