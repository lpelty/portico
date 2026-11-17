import SwiftUI

/// One team knowledge notice in the strip (v0.27, Bill's ZJ3). A notice
/// that needs the person is a tinted pill with its button; the quiet line
/// is plain words with a link. With no room it is its icon, and the whole
/// of it is the click.
struct TeamNoticeView: View {
    var notice: TeamNotice
    var fit: TeamStripPresentation.Fit
    var act: () -> Void

    @EnvironmentObject private var model: AppModel

    private typealias Measure = TeamStripPresentation.Measure

    var body: some View {
        let words = notice.words(at: fit)
        Button(action: act) {
            HStack(spacing: 0) {
                Image(systemName: notice.icon)
                    .font(Theme.iconFont(Measure.iconSize))
                    .foregroundStyle(iconColour)
                if let words {
                    Text(words)
                        .scaledFont(12)
                        .foregroundStyle(wordColour)
                        .padding(.leading, Measure.iconGap)
                    if let button = notice.button {
                        Text(button)
                            .scaledFont(12, weight: .semibold)
                            .foregroundStyle(notice.tone == .wait ? Theme.onWait : Theme.onAccent)
                            .padding(.horizontal, Measure.buttonPadding)
                            .padding(.vertical, 1)
                            .background(tone, in: RoundedRectangle(cornerRadius: 4))
                            .padding(.leading, Measure.buttonGap)
                    }
                    if let link = notice.link {
                        Text(link)
                            .scaledFont(12)
                            .foregroundStyle(accent)
                            .padding(.leading, Measure.linkGap)
                    }
                }
            }
            .padding(.horizontal, notice.tone == .quiet ? 0 : Measure.pillPadding)
            .padding(.vertical, 3)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(notice.kind == .getting)
        .tip(notice.help)
        .accessibilityLabel(notice.button.map { "\(notice.full). \($0)" } ?? notice.full)
    }

    private var accent: Color { model.brand.accent ?? Theme.accent }

    private var tone: Color {
        notice.tone == .wait ? Theme.wait : accent
    }

    private var fill: Color {
        switch notice.tone {
        case .accent: Theme.accentSoft
        case .wait: Theme.waitSoft
        case .quiet: .clear
        }
    }

    private var wordColour: Color {
        notice.tone == .quiet ? Theme.text2 : tone
    }

    private var iconColour: Color {
        if notice.tone == .quiet { return notice.icon == "checkmark" ? Theme.working : Theme.text2 }
        return tone
    }
}
