import AppKit
import SwiftUI

// MARK: - SessionFileOrigin

/// Who put a file in the session's list (v0.17 §3.6, ruling 7): the agent
/// made it (a write, `show_in_viewer`, the producer: anything the gateway
/// announced), or the person opened it from the Files pane (a `local:`
/// artifact the app made itself).
enum SessionFileOrigin: Equatable {
    case made, opened

    @MainActor static func of(_ artifact: Artifact) -> SessionFileOrigin {
        AppModel.isLocal(artifact) ? .opened : .made
    }

    /// The row's icon: a sparkle for made, an eye for opened.
    var systemImage: String {
        switch self {
        case .made: "sparkles"
        case .opened: "eye"
        }
    }

    /// What the icon says to VoiceOver.
    var accessibilityLabel: String {
        switch self {
        case .made: "Made by the agent"
        case .opened: "Opened by you"
        }
    }
}

// MARK: - SessionFilesPresentation

/// What the "This session" list shows (v0.17 §3.6): every file, newest
/// first, with a one-line filter once there are more than 12.
struct SessionFilesPresentation: Equatable {
    /// The list's rows, newest first (`AppModel.history(for:)`).
    let files: [Artifact]
    let query: String

    /// Past this many files, the filter appears.
    static let filterThreshold = 12

    var showsFilter: Bool { files.count > Self.filterThreshold }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The files whose title or location contains the query, ignoring
    /// case, in the order given.
    var shown: [Artifact] {
        let needle = trimmed.lowercased()
        guard !needle.isEmpty else { return files }
        return files.filter { file in
            [ArtifactPresentation(artifact: file).title, file.location].contains { $0.lowercased().contains(needle) }
        }
    }

    /// Set when a filter matched nothing.
    var emptyMessage: String? {
        guard !trimmed.isEmpty, shown.isEmpty else { return nil }
        return "Nothing in this session matches “\(trimmed)”"
    }

    /// Whether `row` is the file in front. By location, not id: a row is
    /// its file's newest showing, and the one in front may be an older
    /// artifact for the same file.
    static func isInFront(_ row: Artifact, current: Artifact?) -> Bool {
        current?.location == row.location
    }
}

// MARK: - ArtifactMenu

/// The viewer title's menu, "This session": the files the agent made and
/// the ones the person opened, newest first, each led by its type's icon
/// and marked made or opened after its title; a filter
/// past 12. A pick shows it; every row can open externally.
struct ArtifactMenu: View {
    let chat: Int
    let artifacts: [Artifact]
    let onPick: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        let list = SessionFilesPresentation(files: artifacts, query: query)
        VStack(alignment: .leading, spacing: 2) {
            Text(model.madeHereLabel.uppercased())
                .scaledFont(10, weight: .semibold)
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            if list.showsFilter {
                filterField
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
            if let empty = list.emptyMessage {
                Text(empty)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(list.shown, id: \.id) { artifact in
                            row(artifact)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(6)
        .frame(width: 340)
        .onAppear {
            guard list.showsFilter else { return }
            DispatchQueue.main.async { filterFocused = true }
        }
    }

    /// As History's search field: a magnifying glass and a plain field.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.iconFont(12))
                .foregroundStyle(Theme.text3)
            TextField("Filter files", text: $query)
                .textFieldStyle(.plain)
                .scaledFont(12)
                .focused($filterFocused)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private func row(_ artifact: Artifact) -> some View {
        let shown = ArtifactPresentation(artifact: artifact)
        let origin = SessionFileOrigin.of(artifact)
        let isCurrent = SessionFilesPresentation.isInFront(artifact, current: model.current[chat])
        return Button {
            model.show(artifact, in: chat)
            onPick()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: shown.systemImage)
                    .font(Theme.iconFont(12))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(shown.title)
                            .scaledFont(13)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Made or opened: a small mark after the title.
                        Image(systemName: origin.systemImage)
                            .font(Theme.iconFont(9))
                            .foregroundStyle(Theme.text2)
                            .tip(origin.accessibilityLabel)
                            .accessibilityLabel(origin.accessibilityLabel)
                    }
                    Text(shown.kindLabel)
                        .scaledFont(11)
                        .foregroundStyle(Theme.text2)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(Theme.iconFont(11, weight: .semibold))
                        .foregroundStyle(model.brand.accent ?? Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isCurrent ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .tip(shown.subtitle)
        .contextMenu {
            Button("Open externally") { shown.openExternally() }
        }
    }
}
