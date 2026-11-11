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
    private var order: [String] = []
    private var entries: [String: TranscriptEntry] = [:]
    /// Reply lengths, turn ends and tool rows already written; kept up to date
    /// from the items walked since the last change, never rebuilt from scratch.
    private var replyChars: [String: Int] = [:]
    private var turnEnds: Set<String> = []
    private var toolRows: Set<String> = []
    private var itemsKey = ""
    /// The item count and the last item's id at the last change: items before
    /// that index are taken as unchanged while that id is still in its place.
    private var itemCount = 0
    private var lastItemID: String?
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
    /// rows are a closure: a streaming delta never needs them.
    struct Snapshot {
        var items: [TranscriptItem]
        var itemsKey: String
        var docked: String?
        /// The turn a reply with no turn end after it belongs to (the model's current turn).
        var currentTurn: Int?
        var layout: () -> Layout
    }

    struct Layout {
        var drawn: [TranscriptEntry]
        var briefItem: String?
        var divider: Bool
    }

    /// Writes `open`, then one shape per drawn entry.
    func start(_ recorder: Recorder, open: RecordingEvent, window: [Int], snapshot: Snapshot) {
        self.recorder = recorder
        shapes = [:]
        entries = [:]
        replyChars = [:]
        turnEnds = []
        toolRows = []
        viewer = nil
        recorder.note(open)
        self.window = window
        let now = shapeList(snapshot.layout())
        for shape in now { recorder.note(.shape(shape)) }
        remember(now)
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
    /// sizes (ruling 1), shapes that changed and ids gone. Only the items after
    /// the last change are walked; a streaming delta (the same items, the last
    /// reply longer) writes its growth and, at most every `tailShapeInterval`,
    /// the reply's shape, without the drawn rows.
    func changed(_ snapshot: Snapshot) {
        guard let recorder else { return }
        if snapshot.docked != docked {
            if let old = docked { recorder.note(.card(id: old, docked: false)) }
            if let new = snapshot.docked { recorder.note(.card(id: new, docked: true)) }
            docked = snapshot.docked
        }
        guard snapshot.itemsKey != itemsKey else { return }
        let items = snapshot.items
        if items.count == itemCount, let last = items.last, last.id == lastItemID, case .assistantText = last {
            walk(snapshot, from: items.count - 1, write: true)
            if now() - tailShapedAt >= Self.tailShapeInterval { shapeTail(last) }
            mark(snapshot)
            return
        }
        let unchangedBefore = itemCount > 0 && items.count >= itemCount && items[itemCount - 1].id == lastItemID
        walk(snapshot, from: unchangedBefore ? itemCount - 1 : 0, write: true)
        let now = shapeList(snapshot.layout())
        let ids = Set(now.map(\.id))
        for shape in now where shapes[shape.id] != shape { recorder.note(.shape(shape)) }
        for id in order where !ids.contains(id) { recorder.note(.removed(id: id)) }
        remember(now)
        tailShapedAt = self.now()
        mark(snapshot)
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
        itemCount = snapshot.items.count
        lastItemID = snapshot.items.last?.id
        docked = snapshot.docked
    }

    private func remember(_ now: [EntryShape]) {
        shapes = Dictionary(now.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        order = now.map(\.id)
    }

    /// A reply's turn: the first turn end after it, else the model's current turn.
    static func turn(ofReplyAt index: Int, in items: [TranscriptItem], current: Int?) -> Int? {
        for item in items[(index + 1)...] {
            if case .turnMarker(let marker) = item { return marker.turn }
        }
        return current
    }

    /// One shape per drawn entry, the divider first and the brief in its entry's
    /// place (ids only); an entry unchanged since the last call keeps its shape.
    private func shapeList(_ layout: Layout) -> [EntryShape] {
        var out: [EntryShape] = []
        if layout.divider { out.append(EntryShape(id: "divider", kind: .divider)) }
        var seen: [String: TranscriptEntry] = [:]
        for entry in layout.drawn {
            let id = entry.id
            if id == layout.briefItem {
                out.append(EntryShape(id: "brief", kind: .brief))
                continue
            }
            seen[id] = entry
            if let old = entries[id], old == entry, let shape = shapes[id] {
                out.append(shape)
            } else {
                out.append(EntryShape.of(entry, imageSize: imageSize))
            }
        }
        entries = seen
        return out
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
