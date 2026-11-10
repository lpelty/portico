// v0.16 §5 spike (Task 9), hosted (`ConversationRoundTripTests`' window,
// wheel and key helpers), the transcript on `.scrollPosition($position)`:
// 1. The app's `position.scrollTo(edge: .bottom)`: `isPositionedByUser`
//    false, as it should be.
// 2. A wheel (the clip moved inside a live scroll, and a trackpad's phased
//    events alike): `isPositionedByUser` false. The position does move to
//    the message at the top (`viewID`), and the scroll phase is reported.
// 3. Page Up through `animatedKey` (the clip moved, no live scroll):
//    `isPositionedByUser` false, and the position does not move: it still
//    says the bottom edge, and SwiftUI puts the view back there when the
//    content next grows.
// 4. VoiceOver's page (`accessibilityScrollAction`, a pixel wheel handed
//    to the scroll view): `isPositionedByUser` false; the position moves
//    to the message at the top.
// 5. `.defaultScrollAnchor(.bottom, for: .sizeChanges)`: scrolled up, a
//    growing reply leaves the view where it is; at the bottom it follows.
//    Not adopted: following stays the memory's, which already holds.
// So `isPositionedByUser` misses every input on macOS here, and v0.15's
// marks all stay: `scrolling` is the scroll phase, and `marked` the key
// and wheel monitor and VoiceOver's cursor (`TranscriptPersonInput`).
// What ScrollPosition brings: an edge target that SwiftUI drops when the person scrolls (v0.15's id target was put back
// once, R10), so the first scroll after opening holds; the per-conversation
// place (`ConversationPlace`); and stale app-set targets to clear (3): the
// bottom edge, and the row a restore scrolled to (fix round 1).

import SwiftUI

/// Whether the conversation was last seen at its bottom, so a change of
/// the column's width (the viewer opening or closing, a space opening or
/// going back to Work, the sidebar folding) keeps it there (v0.11
/// decision 6, item 67).
///
/// A narrower column wraps every line again and the transcript grows, so
/// the bottom is no longer the bottom: that case scrolls back to it. A
/// conversation scrolled up is left alone: the scroll view's own position
/// (`scrollPosition(id:anchor:)`) keeps the message at the top and the
/// point in it across the reflow. v0.14 fix: this used to scroll to the
/// start of a remembered top message as well, which was coarse (the start
/// of a long reply, not the line being read) and could be stale (noted
/// only when the view left the bottom), so a space and back jumped the
/// conversation to another place.
struct ConversationScrollMemory: Equatable, Sendable {
    /// How close to the end still counts as at the bottom.
    static let bottomSlack: CGFloat = 24

    /// Where to scroll after the width changes.
    enum Target: Equatable, Sendable {
        case bottom
    }

    /// Which way the person's marked input scrolls (v0.15 fix round 4):
    /// `.up` toward earlier messages, `.down` toward the newest, `.either`
    /// when the input says nothing of it (VoiceOver's cursor).
    enum Direction: Equatable, Sendable {
        case up, down, either
    }

    /// At the bottom until the person scrolls away: a conversation opens there.
    private(set) var atBottom = true
    /// The column's width the place was last seen at.
    private(set) var width: CGFloat?
    /// The offset at the last reading (v0.15 task 2b fix round 3).
    private(set) var offset: CGFloat?
    /// Whether an offset is at the end of the content (or the content fits).
    static func isAtBottom(offset: CGFloat, visible: CGFloat, content: CGFloat) -> Bool {
        content <= visible || offset + visible >= content - bottomSlack
    }

    /// The conversation is seen at this place (scrolled there, or following the newest message).
    mutating func seen(atBottom: Bool, width: CGFloat) {
        self.atBottom = atBottom
        self.width = width
    }

    /// The conversation is put back at the place it was left at (v0.16
    /// §5): its readings until the person scrolls are the restore's.
    mutating func restored(atBottom: Bool) {
        self.atBottom = atBottom
    }

    /// The app scrolled to the end itself (the person's send, or following
    /// the newest message): the conversation is at its bottom (v0.15 task 2b
    /// fix round 1; the jump's own readings are not the person's).
    mutating func followed() {
        atBottom = true
    }

    /// v0.26 (PORT-12): a marker's click took the conversation to a message:
    /// it is no longer at its bottom, so a streaming reply doesn't pull it down.
    mutating func jumped() {
        atBottom = false
    }

    /// One scroll-geometry reading, as the view gets it: its width, whether
    /// it is at the end, and whether the person is scrolling (the scroll
    /// view's phase). Returns where to scroll, if anywhere.
    ///
    /// A reading taken on a frame whose width changed is the reflow's, not
    /// the person's (fix round 1): scrolled up near the end, a step of the
    /// column's animation can read as the bottom, and recording it would
    /// snap the conversation to its end at the next change.
    ///
    /// v0.15 fix (task 2b): nor is any reading taken while the person is
    /// not scrolling. Found hosted: the width step scrolled to the end of
    /// the lazy stack's estimate, the rows then resolved at the new width
    /// and the end moved (189 pt), and at an unchanged width the layout
    /// moved the offset by itself (134 pt, content unchanged) and the
    /// app's own scroll landed short; each was taken for the person leaving
    /// the bottom, or never seen again. Only the person's scroll (and the
    /// app's `followed()`) moves the memory now. Any other reading off the
    /// end, while the memory says at the bottom, goes back to the bottom;
    /// scrolled up, it is left alone.
    ///
    /// Fix round 3: a reading of the person's off the end says they left
    /// the bottom only when the offset moved toward the top since the last
    /// reading. Back at the end while a reply streams, the reading after
    /// their scroll (still theirs for a moment) can land off the end
    /// because the content grew; it moved down or not at all, so it is the
    /// layout's.
    ///
    /// Fix round 4: a marked input (a scroll key, a wheel, VoiceOver;
    /// `marked`, its direction) counts for the readings that move the offset
    /// its way, all of them: an animated key scroll reaches the end over
    /// several frames. A reading moving the other way, or not at all, is
    /// the layout's (SwiftUI putting its own offset back, a reply delta),
    /// never recorded as the person's. Under an up mark it is ignored
    /// outright: going back to the bottom there (a delta landing before the
    /// key's first frame) would swallow the key. Under a down mark it gets
    /// the layout's rule, back to the bottom when the memory is there: found
    /// hosted, SwiftUI put 6756 back to 6710 again and again after a wheel
    /// back to the end, and ignoring those left the view short of the end.
    /// A scroll phase (`scrolling`) is the person's whatever the direction.
    mutating func observe(
        width: CGFloat, atBottom: Bool, scrolling: Bool, marked: Direction? = nil, offset: CGFloat? = nil
    ) -> Target? {
        let previous = self.offset
        if let offset { self.offset = offset }
        if let known = self.width, abs(known - width) >= 1 {
            return widthChanged(to: width)
        }
        // Toward the end is positive; unknown without two readings.
        let moved = offset.flatMap { now in previous.map { now - $0 } }
        var person = scrolling
        if !scrolling, let marked {
            switch marked {
            case .either:
                person = true
            case .up:
                guard moved.map({ $0 < -0.5 }) ?? true else { return nil }
                person = true
            case .down:
                person = moved.map { $0 > 0.5 } ?? true
            }
        }
        if person {
            let movedUp = moved.map { $0 < -0.5 } ?? true
            if atBottom || movedUp || !self.atBottom {
                seen(atBottom: atBottom, width: width)
                return nil
            }
            return .bottom
        }
        guard self.width != nil else {
            self.width = width  // the first look: a conversation opens at its bottom
            return nil
        }
        return self.atBottom && !atBottom ? .bottom : nil
    }

    /// The column became `newWidth` wide: `.bottom` when it was at the
    /// bottom; `nil` when nothing changed, nothing is known, or it was
    /// scrolled up (the scroll view keeps that place itself).
    mutating func widthChanged(to newWidth: CGFloat) -> Target? {
        defer { width = newWidth }
        guard let width, abs(width - newWidth) >= 1 else { return nil }
        return atBottom ? .bottom : nil
    }
}

/// Where each drawn transcript row sits in the scroll view's visible area
/// (v0.16 §5), as the lazy stack lays them out: the place a conversation
/// keeps while another is shown is the row at the top and the point in it.
/// A reference, not state: a row moving redraws nothing.
@MainActor
final class TranscriptRowFrames {
    private(set) var frames: [String: CGRect] = [:]
    /// The chat these rows are, for the scroll trace's row lines.
    var traceChat = 0

    func note(_ frame: CGRect, id: String) {
        if ScrollTrace.enabled, let line = ScrollTrace.rowLine(chat: traceChat, id: id, old: frames[id], new: frame) {
            ScrollTrace.note(line)
        }
        frames[id] = frame
    }

    func forget(_ id: String) {
        if ScrollTrace.enabled, frames[id] != nil { ScrollTrace.note(ScrollTrace.rowGoneLine(chat: traceChat, id: id)) }
        frames[id] = nil
    }

    /// What else the stack draws under the rows (calling cards, the working
    /// line): counted as drawn by the blank-space diagnostic, never the
    /// place a conversation keeps.
    private(set) var others: [String: CGRect] = [:]

    func noteOther(_ frame: CGRect, id: String) { others[id] = frame }
    func forgetOther(_ id: String) { others[id] = nil }

    /// Every drawn thing's frame: the rows and the others.
    var allFrames: [CGRect] { Array(frames.values) + Array(others.values) }

    /// The row at the top of the view (the first whose bottom is below the
    /// view's top) and its top's distance from the view's top.
    func top() -> (id: String, offset: CGFloat)? {
        frames.filter { $0.value.maxY > 0 }.min { $0.value.minY < $1.value.minY }
            .map { ($0.key, $0.value.minY) }
    }
}

/// A transcript row that reports its frame in the scroll view to `rows`
/// while it is laid out (v0.16 §5).
struct ReportsRowFrame: ViewModifier {
    let rows: TranscriptRowFrames
    let id: String
    /// A transcript row (the place a conversation keeps can be it), or
    /// something drawn under the rows (a calling card, the working line).
    var isRow = true

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                if isRow { rows.note(frame, id: id) } else { rows.noteOther(frame, id: id) }
            }
            .onDisappear { if isRow { rows.forget(id) } else { rows.forgetOther(id) } }
    }
}
