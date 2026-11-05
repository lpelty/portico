import AppKit
import SwiftUI

/// The zoom steps and what Fit means (v0.20 §3.1). Shared by the image pane
/// and, in Task 7, the PDF pane.
enum Zoom {
    static let steps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 8]
    static let minimum: CGFloat = 0.25
    static let maximum: CGFloat = 8

    private static let slack: CGFloat = 0.005

    /// The next step above `value`; the last step stays the last.
    static func next(after value: CGFloat) -> CGFloat {
        steps.first { $0 > value + slack } ?? steps[steps.count - 1]
    }

    /// Zoom Out: the next step below, never an enlargement (a Fit under the first step stays).
    static func out(from value: CGFloat) -> CGFloat { min(previous(before: value), value) }

    /// The next step below `value`; the first step stays the first.
    static func previous(before value: CGFloat) -> CGFloat {
        steps.last { $0 < value - slack } ?? steps[0]
    }

    /// The scale at which `image` fits in `box`, never past 100%.
    static func fit(image: CGSize, in box: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return 1 }
        return min(1, box.width / image.width, box.height / image.height)
    }
}

/// What a file was last zoomed to, for the session; Fit is stored as nil, so
/// a file never zoomed (or left at Fit) opens at Fit.
@MainActor
final class ZoomMemory {
    static let shared = ZoomMemory()
    private var scales: [String: CGFloat] = [:]

    /// The remembered scale, or nil for Fit.
    func scale(for path: String) -> CGFloat? { scales[path] }

    func set(_ scale: CGFloat?, for path: String) {
        if let scale { scales[path] = scale } else { scales[path] = nil }
    }
}

/// What the View menu's zoom commands talk to: the shown image or PDF.
@MainActor
protocol ZoomTarget: AnyObject {
    func zoomIn()
    func zoomOut()
    func zoomToFit()
}

/// The zoomable pane in each viewer slot, for the menu.
@MainActor
final class ZoomHub {
    static let shared = ZoomHub()
    private var targets: [ViewerAgent.Slot: WeakTarget] = [:]
    private struct WeakTarget { weak var target: (any ZoomTarget)? }

    func register(_ target: any ZoomTarget, slot: ViewerAgent.Slot?) {
        targets[slot ?? .work] = WeakTarget(target: target)
    }

    func unregister(_ target: any ZoomTarget, slot: ViewerAgent.Slot?) {
        if targets[slot ?? .work]?.target === target { targets[slot ?? .work] = nil }
    }

    func target(space: Bool) -> (any ZoomTarget)? { targets[space ? .space : .work]?.target }
}

/// When the View menu's zoom commands are on: the shown file is an image or a PDF.
enum ZoomMenu {
    static func isEnabled(media: Media?, missing: Bool = false) -> Bool {
        guard let media, !missing else { return false }
        return media == .image || media == .pdf
    }
}

/// A small floating control: out, the percent (click for 100%), in, Fit; and
/// a page counter for a PDF. A solid panel capsule; it fades after 2 s of a
/// still pointer, and stays while VoiceOver is running.
struct ZoomControl: View {
    let percent: Int
    var page: String?
    let onIn: () -> Void
    let onOut: () -> Void
    let onFit: () -> Void
    let onActual: () -> Void
    /// Whether the pointer moved lately (the pane drives it).
    var awake: Bool = true

    static let fadeDelay: Duration = .seconds(2)

    private var shown: Bool { awake || NSWorkspace.shared.isVoiceOverEnabled }

    static func percentText(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded()))%" }

    var body: some View {
        HStack(spacing: 2) {
            if let page {
                Text(page)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8)
                Divider().frame(height: 14)
            }
            button("minus", "Zoom Out", onOut)
            Text("\(percent)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 44)
                .accessibilityLabel("Zoom, \(percent) percent")
            button("plus", "Zoom In", onIn)
            Divider().frame(height: 14)
            button("arrow.up.left.and.arrow.down.right", "Zoom to Fit", onFit)
            button("1.magnifyingglass", "Actual size (100%)", onActual)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(.easeOut(duration: 0.25), value: awake)
        .accessibilityElement(children: .contain)
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Fades a control after `ZoomControl.fadeDelay` of a still pointer.
struct ZoomWake: ViewModifier {
    @Binding var awake: Bool
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                if case .active = phase { wake() }
            }
            .onAppear { wake() }
            .onDisappear { task?.cancel() }
    }

    private func wake() {
        awake = true
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: ZoomControl.fadeDelay)
            if !Task.isCancelled { awake = false }
        }
    }
}
