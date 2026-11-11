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
    private var replyChars: [String: Int] = [:]
    private var turnEnds: Set<String> = []
    private var toolRows: Set<String> = []
    private var itemsKey = ""
    private var docked: String?
    private var window: [Int]?
    private var imageSizes: [String: [Int]] = [:]

    /// What the transcript holds at one moment, as the view sees it.
    struct Snapshot {
        var items: [TranscriptItem]
        var drawn: [TranscriptEntry]
        var briefItem: String?
        var divider: Bool
        var itemsKey: String
        var docked: String?
        /// The turn a reply with no turn end after it belongs to (the model's current turn).
        var currentTurn: Int?
    }

    /// Writes `open`, then one shape per drawn entry.
    func start(_ recorder: Recorder, open: RecordingEvent, window: [Int], snapshot: Snapshot) {
        self.recorder = recorder
        shapes = [:]
        entries = [:]
        recorder.note(open)
        self.window = window
        let now = shapeList(snapshot)
        for shape in now { recorder.note(.shape(shape)) }
        remember(now, snapshot: snapshot)
    }

    func stop() {
        recorder = nil
    }

    func note(_ event: RecordingEvent) {
        recorder?.note(event)
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

    /// Page Up, Page Down, Home and End; the arrows and Space have no `ScrollKey`.
    static func key(_ code: UInt16) -> ScrollKey? {
        switch code {
        case 116: .pageUp
        case 121: .pageDown
        case 115: .home
        case 119: .end
        default: nil
        }
    }

    /// The transcript changed (the view's follow key): shapes that changed,
    /// ids gone, and the gateway's events as sizes (ruling 1).
    func changed(_ snapshot: Snapshot) {
        guard let recorder else { return }
        if snapshot.docked != docked {
            if let old = docked { recorder.note(.card(id: old, docked: false)) }
            if let new = snapshot.docked { recorder.note(.card(id: new, docked: true)) }
            docked = snapshot.docked
        }
        guard snapshot.itemsKey != itemsKey else { return }
        let items = snapshot.items
        for (index, item) in items.enumerated() {
            switch item {
            case .assistantText(_, let text, _):
                let id = item.id
                let grew = text.count - (replyChars[id] ?? 0)
                if grew > 0, let turn = Self.turn(ofReplyAt: index, in: items, current: snapshot.currentTurn) {
                    recorder.note(.delta(turn: turn, chars: grew))
                }
            case .turnMarker(let marker):
                if !turnEnds.contains(item.id) { recorder.note(.turnFinished(turn: marker.turn)) }
            case .tool:
                if !toolRows.contains(item.id) { recorder.note(.toolRow(id: item.id)) }
            default:
                break
            }
        }
        let now = shapeList(snapshot)
        let ids = Set(now.map(\.id))
        for shape in now where shapes[shape.id] != shape { recorder.note(.shape(shape)) }
        for id in order where !ids.contains(id) { recorder.note(.removed(id: id)) }
        remember(now, snapshot: snapshot)
    }

    private func remember(_ now: [EntryShape], snapshot: Snapshot) {
        shapes = Dictionary(now.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        order = now.map(\.id)
        itemsKey = snapshot.itemsKey
        docked = snapshot.docked
        replyChars = [:]
        turnEnds = []
        toolRows = []
        for item in snapshot.items {
            switch item {
            case .assistantText(_, let text, _): replyChars[item.id] = text.count
            case .turnMarker: turnEnds.insert(item.id)
            case .tool: toolRows.insert(item.id)
            default: break
            }
        }
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
    private func shapeList(_ snapshot: Snapshot) -> [EntryShape] {
        var out: [EntryShape] = []
        if snapshot.divider { out.append(EntryShape(id: "divider", kind: .divider)) }
        var seen: [String: TranscriptEntry] = [:]
        for entry in snapshot.drawn {
            let id = entry.id
            if id == snapshot.briefItem {
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
