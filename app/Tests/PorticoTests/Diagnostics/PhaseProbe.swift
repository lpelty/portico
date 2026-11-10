import AppKit
import XCTest

@testable import Portico

/// D12: feeds two began / changed x3 / ended wheel gestures, with scroll-phase
/// fields set, into a hosted transcript scroll view and reports whether
/// SwiftUI's `onScrollPhaseChange` saw a non-idle phase and whether the offset
/// moved. Two gestures because SwiftUI puts the first scroll after the app's
/// scroll to the bottom back once. Reusable by the replay runner.
@MainActor
enum PhaseProbe {
    struct Result {
        var phased: Bool
        /// Net offset change over the second gesture (points).
        var moved: CGFloat
        var atBottomBefore: Bool
        /// Offset before, after each step, and after each gesture settles.
        var offsets: [CGFloat]
    }

    static func phased(scroll: NSScrollView, chat: Int) -> Bool {
        run(scroll: scroll, chat: chat).phased
    }

    static func run(scroll: NSScrollView, chat: Int) -> Result {
        let wasEnabled = ConversationProbe.enabled
        ConversationProbe.enabled = true
        defer { ConversationProbe.enabled = wasEnabled }
        ConversationProbe.phaseNames[chat] = nil

        let clip = scroll.contentView
        let height = scroll.documentView?.frame.height ?? 0
        let atBottomBefore = clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        var offsets: [CGFloat] = [clip.bounds.origin.y]
        var secondStart = offsets[0]

        let steps: [(phase: NSEvent.Phase, pixels: Int32)] = [
            (.began, 0), (.changed, 40), (.changed, 40), (.changed, 40), (.ended, 0),
        ]
        for gesture in 0..<2 {
            if gesture == 1 { secondStart = clip.bounds.origin.y }
            for step in steps {
                guard send(step.phase, step.pixels, to: scroll) else {
                    return Result(phased: false, moved: 0, atBottomBefore: atBottomBefore, offsets: offsets)
                }
                spin(0.05)
                offsets.append(clip.bounds.origin.y)
            }
            spin(0.6)
            offsets.append(clip.bounds.origin.y)
        }
        let seen = ConversationProbe.phaseNames[chat] ?? []
        return Result(phased: seen.contains { $0 != "idle" },
                      moved: clip.bounds.origin.y - secondStart,
                      atBottomBefore: atBottomBefore, offsets: offsets)
    }

    private static func send(_ phase: NSEvent.Phase, _ pixels: Int32, to scroll: NSScrollView) -> Bool {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: pixels, wheel2: 0, wheel3: 0) else { return false }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        let inWindow = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screen = scroll.window?.convertPoint(toScreen: inWindow) ?? inWindow
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: screen.x, y: top - screen.y)
        guard let event = NSEvent(cgEvent: cg) else { return false }
        NSApp.sendEvent(event)
        scroll.scrollWheel(with: event)
        return true
    }

    static func spin(_ seconds: Double = 0.4) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
