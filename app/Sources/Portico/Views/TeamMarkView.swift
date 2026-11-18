import SwiftUI

/// A team file's mark at the right edge of its row (v0.27, Bill's ZJ4).
/// A going-out mark opens the wait with Send now and Pause; a paused one
/// resumes; a two-versions one opens the file.
struct TeamMarkView: View {
    let file: TeamFile
    let state: TeamState

    @EnvironmentObject private var model: AppModel
    @State private var shown = false

    var body: some View {
        let mark = TeamMarkPresentation.make(file, state: state)
        Button {
            switch mark.click {
            case .nothing: break
            case .sendOrPause: shown = true
            case .resume: model.teamSetPaused(file, false)
            case .open: model.teamOpen(file.path)
            }
        } label: {
            Image(systemName: mark.icon)
                .font(Theme.iconFont(10, weight: .semibold))
                .foregroundStyle(colour(mark.tone))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(mark.click != .nothing)
        .tip(mark.help)
        .accessibilityLabel(mark.title)
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            HStack(spacing: 10) {
                Image(systemName: "hourglass")
                    .font(Theme.iconFont(11))
                    .foregroundStyle(Theme.text2)
                Text(TeamMarkPresentation.goes(nextCheckAt: state.nextCheckAt, words: .system))
                    .scaledFont(12)
                    .foregroundStyle(Theme.text)
                Button("Send now") {
                    shown = false
                    model.teamSendNow(file)
                }
                .buttonStyle(SettingsButtonStyle(kind: .accent))
                Button("Pause") {
                    shown = false
                    model.teamSetPaused(file, true)
                }
                .buttonStyle(SettingsButtonStyle(kind: .quiet))
            }
            .padding(10)
            .popoverSurface()
        }
    }

    private func colour(_ tone: TeamMarkPresentation.Tone) -> Color {
        switch tone {
        case .grey: Theme.text3
        case .accent: model.brand.accent ?? Theme.accent
        case .wait: Theme.wait
        }
    }
}

/// The team items of a file row's menu (ZJ1).
struct TeamFileMenuItems: View {
    let file: TeamFile
    let state: TeamState

    @EnvironmentObject private var model: AppModel

    var body: some View {
        let menu = TeamFileMenu.make(file)
        Divider()
        if menu.sendNow {
            let wait = TeamMarkPresentation.wait(nextCheckAt: state.nextCheckAt, words: .system)
            Button("Send changes now" + (wait.map { "  (\($0))" } ?? "")) { model.teamSendNow(file) }
        }
        if menu.pause { Button("Pause sending") { model.teamSetPaused(file, true) } }
        if menu.resume { Button("Resume sending") { model.teamSetPaused(file, false) } }
        if menu.stop {
            Divider()
            Button("Stop syncing") { model.teamStop(file) }
        }
    }
}
