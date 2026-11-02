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

/// The docked card's frame (v0.16, AO1): docked above the composer at the
/// composer's width. The header holds the title, an optional pager and ×;
/// under it a left column (the options) and, when `showsTrailing`, a right
/// column of the same height (a question's preview). Without the right
/// column the left one takes the full width. A question card draws itself
/// in it now; Task 7 draws a permission card in it too (tool and target
/// as the title, its shipped options at the left, no pager).
struct DockedCard<Leading: View, Trailing: View>: View {
    let title: String
    var pager: DockedCardPager? = nil
    var closeHelp: String = "Dismiss"
    let onClose: () -> Void
    var showsTrailing: Bool = false
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
        // The composer's surface, border and corners (v0.11, AG1), so the
        // card reads as part of it in light and dark.
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
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
            .help(closeHelp)
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
            .help("The question before")
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
            .help("The next question")
            .accessibilityLabel("Next question")
        }
        .foregroundStyle(Theme.text2)
    }
}

extension DockedCard where Trailing == EmptyView {
    /// A card with the left column only.
    init(
        title: String, pager: DockedCardPager? = nil, closeHelp: String = "Dismiss", onClose: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.init(
            title: title, pager: pager, closeHelp: closeHelp, onClose: onClose, showsTrailing: false,
            leading: leading, trailing: { EmptyView() })
    }
}

/// The conversation's dock (v0.16 §3.2, §3.4): the chat's oldest open
/// question or permission card (`AppModel.dockedCard(for:)`), above the
/// status line and the composer, at the composer's width. One card at a
/// time; the next docks when it is answered. A question draws in the
/// `DockedCard` frame; a permission card keeps its shipped card here
/// until Task 7 draws it in the same frame. In a thread it docks in the
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
                    QuestionCard(card: card, accent: model.brand.accent ?? Theme.accent) { model.answerCard($0) }
                case .permission, .form:
                    CardView(card: card, folder: folder) { model.answerCard($0) }
                }
            }
            // A new card is a new draft and takes the focus again.
            .id(card.id)
        }
    }
}
