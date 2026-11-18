import AppKit
import SwiftUI

/// What the Files pane's Shared tab lists (v0.27, Bill's ZJ1): files from
/// the team, then the person's own shared files. The same mark as on any
/// other row of the file.
struct TeamSharedList: Equatable, Sendable {
    /// How many files from the team show before "All N in _team".
    static let fromTeamMax = 8

    var fromTeam: [TeamFile] = []
    /// Every file from the team, when more than are shown.
    var fromTeamTotal = 0
    /// "2 new": files from the team the person has not opened.
    var newCount = 0
    var fromYou: [TeamFile] = []

    static let fromTeamTitle = "From the team"
    static let fromYouTitle = "From you"
    static let emptyTitle = "Nothing shared yet."
    static let emptyHint = "Right-click a file and choose Share with team… to share it. Files other people share appear here once you get them."

    var isEmpty: Bool { fromTeam.isEmpty && fromYou.isEmpty }

    var newText: String? { newCount > 0 ? "\(newCount) new" : nil }

    /// "All 38 in _team", when the list is cut.
    func allText(folder: String) -> String? {
        fromTeamTotal > fromTeam.count ? "All \(fromTeamTotal) in \(folder)" : nil
    }

    /// Files from the team: not yet opened first, then the latest change first. `filter` narrows by name.
    static func make(state: TeamState?, filter: String = "") -> TeamSharedList {
        guard let state else { return TeamSharedList() }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ file: TeamFile) -> Bool {
            needle.isEmpty || URL(fileURLWithPath: file.path).lastPathComponent.lowercased().contains(needle)
        }
        func latest(_ file: TeamFile) -> String { file.changedAt ?? file.sharedAt }
        let incoming = state.files.filter { $0.direction == .in && matches($0) }.sorted {
            if $0.unread != $1.unread { return $0.unread }
            if latest($0) != latest($1) { return latest($0) > latest($1) }
            return $0.path < $1.path
        }
        let outgoing = state.files.filter { $0.direction == .out && matches($0) }.sorted { $0.path < $1.path }
        return TeamSharedList(
            fromTeam: needle.isEmpty ? Array(incoming.prefix(fromTeamMax)) : incoming,
            fromTeamTotal: incoming.count,
            newCount: state.files.filter { $0.direction == .in && $0.unread }.count,
            fromYou: outgoing)
    }
}

/// The Shared tab.
struct TeamSharedView: View {
    let chat: Int
    let filter: String
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let list = TeamSharedList.make(state: model.teamState, filter: filter)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if list.isEmpty {
                    empty
                } else if let state = model.teamState {
                    if !list.fromTeam.isEmpty {
                        heading(TeamSharedList.fromTeamTitle, note: list.newText)
                        ForEach(list.fromTeam) { file in
                            TeamSharedRow(chat: chat, file: file, state: state)
                        }
                        if let all = list.allText(folder: model.team?.folder ?? "") {
                            Button {
                                model.filesTab = .folder
                            } label: {
                                HStack(spacing: 4) {
                                    Text(all).scaledFont(12)
                                    Image(systemName: "chevron.right").font(Theme.iconFont(9, weight: .semibold))
                                }
                                .foregroundStyle(model.brand.accent ?? Theme.accent)
                                .padding(.leading, 38)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tip("Show the folder in Folders")
                        }
                    }
                    if !list.fromYou.isEmpty {
                        heading(TeamSharedList.fromYouTitle, note: nil)
                        ForEach(list.fromYou) { file in
                            TeamSharedRow(chat: chat, file: file, state: state)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
    }

    private func heading(_ title: String, note: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Theme.text2)
            if let note {
                Text(note)
                    .scaledFont(11)
                    .foregroundStyle(model.brand.accent ?? Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TeamSharedList.emptyTitle)
                .scaledFont(12.5)
                .foregroundStyle(Theme.text2)
            Text(TeamSharedList.emptyHint)
                .scaledFont(12)
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// One file in the Shared tab: its name, its mark, and the row's menu.
struct TeamSharedRow: View {
    let chat: Int
    let file: TeamFile
    let state: TeamState
    @EnvironmentObject private var model: AppModel

    private var name: String { URL(fileURLWithPath: file.path).lastPathComponent }
    private var absolutePath: String? { model.teamAbsolutePath(file.path) }

    var body: some View {
        FileLine(
            icon: FileIcon.systemName(for: name), name: name,
            selected: absolutePath != nil && model.current[chat]?.location == absolutePath
        ) {
            TeamMarkView(file: file, state: state)
        }
        .padding(.horizontal, 12)
        .onTapGesture { model.teamOpen(file.path) }
        .contextMenu {
            Button("Open") { model.teamOpen(file.path) }
            if let path = absolutePath {
                Button(model.isBookmarked(path) ? "Remove bookmark" : "Bookmark") { model.toggleBookmark(path) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            TeamFileMenuItems(file: file, state: state)
        }
    }
}
