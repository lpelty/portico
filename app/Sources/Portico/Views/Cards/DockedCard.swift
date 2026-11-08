import SwiftUI

/// The pager in a docked card's header: "‹ 1 of 2 ›". `go` shows another
/// page (the card clamps it).
struct DockedCardPager {
    let page: Int
    let count: Int
    var go: (Int) -> Void = { _ in }

    /// "1 of 2", between the chevrons.
    var text: String { "\(page + 1) of \(count)" }
}

/// How tall a docked card may be (v0.16 fix round 1): about 45% of the
/// conversation, so long options or a long preview scroll inside the card
/// rather than pushing the transcript off. Pure, so it can be tested.
enum DockedCardLayout {
    static let maxShare: CGFloat = 0.45
    /// The card's padding and the gap under the header, around its body.
    static let chrome: CGFloat = 12 + 10 + 10
    /// The body never shrinks below this, however short the window.
    static let minBody: CGFloat = 96

    /// The dock's cap in a conversation `available` points tall.
    static func maxHeight(available: CGFloat) -> CGFloat {
        (available * maxShare).rounded(.down)
    }

    /// The body's cap: the dock's, less the header and the card's chrome;
    /// `nil` (no cap) before the conversation is measured.
    static func bodyCap(dockMax: CGFloat?, header: CGFloat) -> CGFloat? {
        dockMax.map { max($0 - header - chrome, minBody) }
    }

    /// The body's height: its content's, up to the cap (then it scrolls).
    static func bodyHeight(content: CGFloat, cap: CGFloat) -> CGFloat {
        min(content, cap)
    }
}

private struct DockMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The docked card's tallest (`DockedCardLayout.maxHeight`), set by the
    /// conversation; `nil` until it is measured.
    var dockMaxHeight: CGFloat? {
        get { self[DockMaxHeightKey.self] }
        set { self[DockMaxHeightKey.self] = newValue }
    }
}

/// The docked card's frame (v0.16, AO1): docked above the composer at the
/// composer's width. The header holds the title, an optional pager and ×;
/// under it a left column (the options) and, when `showsTrailing`, a right
/// column of the same height (a question's preview). Without the right
/// column the left one takes the full width. A question card and a
/// permission card (tool and target as the title, its shipped options at
/// the left, no pager) both draw in it.
struct DockedCard<Leading: View, Trailing: View>: View {
    let title: String
    /// v0.25: an icon before the title (the sign-in card's key), in its colour.
    var icon: (name: String, colour: Color)? = nil
    var pager: DockedCardPager? = nil
    var closeHelp: String = "Dismiss"
    /// How many lines the title may take; `nil` for all of them.
    var titleLines: Int? = nil
    let onClose: () -> Void
    var showsTrailing: Bool = false
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dockMaxHeight) private var dockMax
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            if let cap = DockedCardLayout.bodyCap(dockMax: dockMax, header: headerHeight) {
                // Up to the cap the body is as tall as its content; past it, it scrolls.
                ScrollView {
                    columns
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: DockedCardLayout.bodyHeight(content: contentHeight, cap: cap))
            } else {
                columns
            }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
        // The composer's surface, border and corners (v0.11, AG1), so the
        // card reads as part of it in light and dark.
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 10) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsTrailing {
                trailing()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon.name)
                    .font(Theme.iconFont(13, weight: .medium))
                    .foregroundStyle(icon.colour)
            }
            Text(title)
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(titleLines)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let pager {
                pagerControls(pager)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Theme.iconFont(11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverBox)
            .tip(closeHelp)
            .accessibilityLabel(closeHelp)
        }
        .padding(.leading, 4)
    }

    private func pagerControls(_ pager: DockedCardPager) -> some View {
        HStack(spacing: 2) {
            Button { pager.go(pager.page - 1) } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.iconFont(10, weight: .semibold))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverBox)
            .disabled(pager.page == 0)
            .tip("The question before")
            .accessibilityLabel("Previous question")
            Text(pager.text)
                .scaledFont(12, monospacedDigit: true)
                .fixedSize()
            Button { pager.go(pager.page + 1) } label: {
                Image(systemName: "chevron.right")
                    .font(Theme.iconFont(10, weight: .semibold))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverBox)
            .disabled(pager.page >= pager.count - 1)
            .tip("The next question")
            .accessibilityLabel("Next question")
        }
        .foregroundStyle(Theme.text2)
    }
}

extension DockedCard where Trailing == EmptyView {
    /// A card with the left column only.
    init(
        title: String, icon: (name: String, colour: Color)? = nil, pager: DockedCardPager? = nil, closeHelp: String = "Dismiss",
        titleLines: Int? = nil, onClose: @escaping () -> Void, @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.init(
            title: title, icon: icon, pager: pager, closeHelp: closeHelp, titleLines: titleLines, onClose: onClose,
            showsTrailing: false, leading: leading, trailing: { EmptyView() })
    }
}

/// The conversation's dock (v0.16 §3.2, §3.4): the chat's oldest open
/// question or permission card (`AppModel.dockedCard(for:)`), above the
/// status line and the composer, at the composer's width. One card at a
/// time; the next docks when it is answered. A question draws in the
/// `DockedCard` frame; a permission card draws in the same frame. In a thread it docks in the
/// thread (Main gets the calling card instead).
struct CardDock: View {
    let chat: Int
    var folder: String? = nil
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let card = model.dockedCard(for: chat) {
            Group {
                switch card.kind {
                case .question:
                    QuestionCard(
                        card: card, accent: model.brand.accent ?? Theme.accent,
                        takesFocus: { [model, chat] in
                            QuestionDockKeys.takesFocusOnAppear(
                                composerFocused: model.focusedComposer == chat, composerText: model.draft(for: chat))
                        }
                    ) { model.answerCard($0) }
                case .permission:
                    PermissionCard(
                        card: card, folder: folder,
                        agentName: model.hello?.brand.agentName ?? model.brand.name,
                        accent: model.brand.accent ?? Theme.accent,
                        takesFocus: { [model, chat] in
                            QuestionDockKeys.takesFocusOnAppear(
                                composerFocused: model.focusedComposer == chat, composerText: model.draft(for: chat))
                        }
                    ) { model.answerCard($0) }
                case .form:
                    CardView(card: card, folder: folder) { model.answerCard($0) }
                }
            }
            // A new card is a new draft and takes the focus again.
            .id(card.id)
        }
    }
}
