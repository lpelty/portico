import AppKit
import ImageIO
import SwiftUI

/// v0.26.4 (D4, D5): one conversation view's side of its recording. It keeps
/// what was last written (shapes, reply lengths, turn ends, tool rows, the
/// docked card, the window) so a change writes only what changed. A
/// reference, so the view's writes to it never redraw the view. The view
/// calls it only while `Diagnostics.isOn`.
@MainActor
final class ConversationRecording {
    private(set) var recorder: Recorder?
    /// Whether the view wants recording (between appear and disappear).
    var wanted = false
    private var shapes: [String: EntryShape] = [:]
    /// The shapes' ids in drawn order, and where each one's entry starts in
    /// the items (`-1` for the divider), so a change reshapes only the tail.
    private var order: [String] = []
    private var starts: [Int] = []
    private var entries: [String: TranscriptEntry] = [:]
    /// The items at the last change (Ruling 14: a structural change works
    /// from the first index where their ids differ).
    private var items: [TranscriptItem] = []
    /// What the drawn rows depended on beyond the items at the last change.
    private var context: Context?
    /// Reply lengths, turn ends and tool rows already written; kept up to date
    /// from the items walked since the last change, never rebuilt from scratch.
    private var replyChars: [String: Int] = [:]
    private var turnEnds: Set<String> = []
    private var toolRows: Set<String> = []
    private var itemsKey = ""
    private var docked: String?
    private var window: [Int]?
    private var viewer: RecordingEvent?
    private var imageSizes: [String: [Int]] = [:]
    /// When the streaming reply's shape was last worked out (at most once per `tailShapeInterval`).
    private var tailShapedAt: TimeInterval = 0
    static let tailShapeInterval: TimeInterval = 0.25
    /// The clock (a test sets its own).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// What the transcript holds at one moment, as the view sees it. The drawn
    /// rows are closures: a streaming delta never needs them, and a structural
    /// change asks only for the tail's.
    struct Snapshot {
        var items: [TranscriptItem]
        var itemsKey: String
        var docked: String?
        /// The turn a reply with no turn end after it belongs to (the model's current turn).
        var currentTurn: Int?
        var context: () -> Context
        /// The drawn rows of `items[from...]`; `from` is never inside a run of tool rows.
        var drawn: (_ from: Int) -> [TranscriptEntry]
    }

    /// What the drawn rows depend on besides the items. When it changes, every
    /// entry is reshaped; otherwise only the tail.
    struct Context: Equatable {
        var briefItem: String?
        var divider: Bool
        /// Tool rows not drawn (an agent's starting row).
        var hidden: Set<String>
        /// Tool rows that split a run (a proposal's card, an app's page).
        var apart: Set<String>
    }

    /// Writes `open`, then one shape per drawn entry.
    func start(_ recorder: Recorder, open: RecordingEvent, window: [Int], snapshot: Snapshot) {
        self.recorder = recorder
        shapes = [:]
        entries = [:]
        order = []
        starts = []
        items = []
        context = nil
        replyChars = [:]
        turnEnds = []
        toolRows = []
        viewer = nil
        recorder.note(open)
        self.window = window
        let context = snapshot.context()
        let tail = shapeList(snapshot, from: 0, context: context, divider: context.divider)
        for shape in tail.shapes { recorder.note(.shape(shape)) }
        remember(tail, keeping: 0)
        self.context = context
        walk(snapshot, from: 0, write: false)
        mark(snapshot)
    }

    func stop() {
        recorder = nil
    }

    func note(_ event: RecordingEvent) {
        recorder?.note(event)
    }

    /// The viewer's state, unless it is the one written last (the shown and
    /// visible changes often come together).
    func noteViewer(_ event: RecordingEvent) {
        guard let recorder, event != viewer else { return }
        viewer = event
        recorder.note(event)
    }

    /// The window's size, when it changed since the last one written.
    func noteWindow(_ size: [Int]) {
        guard let recorder, size != window else { return }
        window = size
        recorder.note(.window(width: size[0], height: size[1]))
    }

    /// A wheel or key the person's input monitor took for the transcript.
    func input(_ event: NSEvent) {
        guard let recorder else { return }
        switch event.type {
        case .scrollWheel:
            recorder.note(.wheel(
                deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
                phase: Int(event.phase.rawValue), momentum: Int(event.momentumPhase.rawValue)))
        case .keyDown:
            if let key = Self.key(event.keyCode) { recorder.note(.key(key)) }
        default:
            break
        }
    }

    /// The transcript's scroll keys (the ones `TranscriptPersonInput` takes).
    static func key(_ code: UInt16) -> ScrollKey? {
        switch code {
        case 116: .pageUp
        case 121: .pageDown
        case 115: .home
        case 119: .end
        case 126: .up
        case 125: .down
        case 49: .space
        default: nil
        }
    }

    /// The transcript changed (the view's follow key): the gateway's events as
    /// sizes (ruling 1), shapes that changed and ids gone. A streaming delta (the
    /// same items, the last reply longer) writes its growth and, at most every
    /// `tailShapeInterval`, the reply's shape, without the drawn rows. Any other
    /// change works only from the first item whose id differs (Ruling 14): the
    /// items before it are unchanged (the model appends, or edits its last
    /// item), so their entries and shapes stand. A tool row finishing earlier
    /// changes no shape. A change of `Context` reshapes every entry.
    func changed(_ snapshot: Snapshot) {
        guard let recorder else { return }
        if snapshot.docked != docked {
            if let old = docked { recorder.note(.card(id: old, docked: false)) }
            if let new = snapshot.docked { recorder.note(.card(id: new, docked: true)) }
            docked = snapshot.docked
        }
        guard snapshot.itemsKey != itemsKey else { return }
        let items = snapshot.items
        if items.count == self.items.count, let last = items.last, let old = self.items.last,
            last.hasSameID(as: old), case .assistantText = last
        {
            walk(snapshot, from: items.count - 1, write: true)
            if now() - tailShapedAt >= Self.tailShapeInterval { shapeTail(last) }
            mark(snapshot)
            return
        }
        // The first item that differs; the last one before the change may have
        // been edited in place, so it is always taken again.
        let before = self.items
        var first = 0
        let common = min(before.count, items.count)
        while first < common, items[first].hasSameID(as: before[first]) { first += 1 }
        first = min(first, max(before.count - 1, 0))
        walk(snapshot, from: first, write: true)

        let context = snapshot.context()
        let all = context != self.context
        // The tail starts where a run of tool rows that reaches `first` starts
        // (a turn end not drawn does not split a run).
        var from = all ? 0 : first
        while from > 0, Self.mayJoinARun(items[from - 1]) { from -= 1 }
        var keep = all ? 0 : order.count
        while keep > 0, starts[keep - 1] >= from { keep -= 1 }
        let tail = shapeList(snapshot, from: from, context: context, divider: all && context.divider)
        let ids = Set(tail.shapes.map(\.id))
        for shape in tail.shapes where shapes[shape.id] != shape { recorder.note(.shape(shape)) }
        for id in order[keep...] where !ids.contains(id) { recorder.note(.removed(id: id)) }
        remember(tail, keeping: keep)
        self.context = context
        tailShapedAt = self.now()
        mark(snapshot)
    }

    /// A tool row (it may fold with the rows before it) or a turn end (one
    /// not drawn leaves the rows around it in one run).
    private static func mayJoinARun(_ item: TranscriptItem) -> Bool {
        switch item {
        case .tool, .turnMarker: true
        default: false
        }
    }

    /// Notes (when `write`) and remembers reply growth, turn ends and tool rows from `start` on.
    private func walk(_ snapshot: Snapshot, from start: Int, write: Bool) {
        let items = snapshot.items
        guard start < items.count else { return }
        for index in start..<items.count {
            let item = items[index]
            switch item {
            case .assistantText(_, let text, _):
                let id = item.id
                let count = text.count
                let grew = count - (replyChars[id] ?? 0)
                if write, grew > 0, let turn = Self.turn(ofReplyAt: index, in: items, current: snapshot.currentTurn) {
                    recorder?.note(.delta(turn: turn, chars: grew))
                }
                replyChars[id] = count
            case .turnMarker(let marker):
                if turnEnds.insert(item.id).inserted, write { recorder?.note(.turnFinished(turn: marker.turn)) }
            case .tool:
                if toolRows.insert(item.id).inserted, write { recorder?.note(.toolRow(id: item.id)) }
            default:
                break
            }
        }
    }

    /// The streaming reply's shape, written when it changed (a drawn reply only).
    private func shapeTail(_ item: TranscriptItem) {
        let id = item.id
        guard let old = shapes[id] else { return }
        let entry = TranscriptEntry.item(item)
        let shape = EntryShape.of(entry, imageSize: imageSize)
        if shape != old { recorder?.note(.shape(shape)) }
        shapes[id] = shape
        entries[id] = entry
        tailShapedAt = now()
    }

    private func mark(_ snapshot: Snapshot) {
        itemsKey = snapshot.itemsKey
        items = snapshot.items
        docked = snapshot.docked
    }

    /// The shapes of the drawn entries from some item on, where each entry
    /// starts in the items, and the entries themselves (the brief's aside).
    private struct Tail {
        var shapes: [EntryShape] = []
        var starts: [Int] = []
        var entries: [(String, TranscriptEntry)] = []
    }

    /// Keeps the first `keep` shapes and puts the tail's after them.
    private func remember(_ tail: Tail, keeping keep: Int) {
        for id in order[keep...] {
            shapes[id] = nil
            entries[id] = nil
        }
        for shape in tail.shapes where shapes[shape.id] == nil { shapes[shape.id] = shape }
        for (id, entry) in tail.entries { entries[id] = entry }
        order.replaceSubrange(keep..., with: tail.shapes.map(\.id))
        starts.replaceSubrange(keep..., with: tail.starts)
    }

    /// A reply's turn: the first turn end after it, else the model's current turn.
    static func turn(ofReplyAt index: Int, in items: [TranscriptItem], current: Int?) -> Int? {
        for item in items[(index + 1)...] {
            if case .turnMarker(let marker) = item { return marker.turn }
        }
        return current
    }

    /// One shape per drawn entry of `items[from...]`, the divider first (when
    /// asked) and the brief in its entry's place (ids only), with the item each
    /// entry starts at; an entry unchanged since the last call keeps its shape.
    private func shapeList(_ snapshot: Snapshot, from: Int, context: Context, divider: Bool) -> Tail {
        var tail = Tail()
        if divider {
            tail.shapes.append(EntryShape(id: "divider", kind: .divider))
            tail.starts.append(-1)
        }
        let items = snapshot.items
        var index = from
        for entry in snapshot.drawn(from) {
            let firstItem: TranscriptItem? = switch entry {
            case .item(let item): item
            case .toolRun(_, let rows): rows.first.map { .tool($0) }
            }
            while index < items.count, let firstItem, !items[index].hasSameID(as: firstItem) { index += 1 }
            tail.starts.append(index)
            let id = entry.id
            if id == context.briefItem {
                tail.shapes.append(EntryShape(id: "brief", kind: .brief))
                continue
            }
            tail.entries.append((id, entry))
            if let old = entries[id], old == entry, let shape = shapes[id] {
                tail.shapes.append(shape)
            } else {
                tail.shapes.append(EntryShape.of(entry, imageSize: imageSize))
            }
        }
        return tail
    }

    /// An image's pixel size from its file's header (no decode), `[0, 0]` when unreadable.
    private func imageSize(_ path: String) -> [Int]? {
        if let known = imageSizes[path] { return known }
        let size = Self.pixelSize(path)
        imageSizes[path] = size
        return size
    }

    nonisolated static func pixelSize(_ path: String) -> [Int] {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return [0, 0] }
        return [width, height]
    }
}

extension ScrollPhaseName {
    /// SwiftUI's scroll phase, by name.
    init?(_ phase: ScrollPhase) {
        switch phase {
        case .idle: self = .idle
        case .tracking: self = .tracking
        case .interacting: self = .interacting
        case .decelerating: self = .decelerating
        case .animating: self = .animating
        @unknown default: return nil
        }
    }
}
