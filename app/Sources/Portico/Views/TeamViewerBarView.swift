import SwiftUI

/// The team bar under the viewer's header (v0.27): amber with the choice
/// when a file has two versions (ZJ6), accent when a change arrived by
/// itself (ZJ1).
struct TeamViewerBarView: View {
    let bar: TeamViewerBar
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isChange ? "arrow.down.left" : "doc.on.doc")
                .font(Theme.iconFont(11, weight: .semibold))
                .foregroundStyle(tone)
            Text(bar.text)
                .scaledFont(12)
                .lineSpacing(2)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isChange {
                Button(TeamViewerBar.seeChanged) { model.teamAct(.latest) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                Button(TeamViewerBar.stop) { model.teamStop(bar.file) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            } else {
                Button(TeamViewerBar.compare) { model.teamCompare(bar) }
                    .buttonStyle(PillButtonStyle(kind: .primary(Theme.wait)))
                Button(TeamViewerBar.useMine) { model.teamResolve(bar.file, use: .mine) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                Button(TeamViewerBar.useTeam) { model.teamResolve(bar.file, use: .team) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
        }
        .lineLimit(nil)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isChange ? Theme.accentSoft : Theme.waitSoft)
    }

    private var isChange: Bool { bar.kind == .changed }

    private var tone: Color {
        isChange ? (model.brand.accent ?? Theme.accent) : Theme.wait
    }
}
