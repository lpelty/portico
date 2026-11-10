import AppKit
import XCTest

@testable import Portico

/// D12: feeds a began / changed x3 / ended wheel gesture, with scroll-phase
/// fields set, into a hosted transcript scroll view and reports whether
/// SwiftUI's `onScrollPhaseChange` saw a non-idle phase. Reusable by the
/// replay runner.
@MainActor
enum PhaseProbe {
    static func phased(scroll: NSScrollView, chat: Int) -> Bool {
        let wasEnabled = ConversationProbe.enabled
        ConversationProbe.enabled = true
        defer { ConversationProbe.enabled = wasEnabled }
        ConversationProbe.phaseNames[chat] = nil

        let steps: [(phase: NSEvent.Phase, pixels: Int32)] = [
            (.began, 0), (.changed, 40), (.changed, 40), (.changed, 40), (.ended, 0),
        ]
        for step in steps {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: step.pixels, wheel2: 0, wheel3: 0) else { return false }
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(step.phase.rawValue))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            let inWindow = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
            let screen = scroll.window?.convertPoint(toScreen: inWindow) ?? inWindow
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            cg.location = CGPoint(x: screen.x, y: top - screen.y)
            guard let event = NSEvent(cgEvent: cg) else { return false }
            NSApp.sendEvent(event)
            scroll.scrollWheel(with: event)
            spin(0.05)
        }
        spin(0.6)
        let seen = ConversationProbe.phaseNames[chat] ?? []
        return seen.contains { $0 != "idle" }
    }

    private static func spin(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
