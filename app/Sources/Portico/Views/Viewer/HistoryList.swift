import AppKit
import SwiftUI

/// Everything the chat has produced, newest first. Picking a row shows it
/// in the viewer; every row can open externally in the system's app.
struct HistoryList: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarSectionLabel("Made in this chat")
                .padding(.horizontal, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.history(for: chat), id: \.id) { artifact in
                        Button {
                            model.show(artifact, in: chat)
                        } label: {
                            HistoryRow(presentation: ArtifactPresentation(artifact: artifact))
                        }
                        .buttonStyle(.plain)
                        .background(
                            model.current[chat]?.id == artifact.id ? Theme.selected : .clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contextMenu {
                            Button("Open externally") { ArtifactPresentation(artifact: artifact).openExternally() }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// One history row: the kind's icon, the title, the location, and an
/// open-externally button.
struct HistoryRow: View {
    let presentation: ArtifactPresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .frame(width: 13)
            Text(presentation.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(presentation.kindLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .help(presentation.subtitle)
    }
}
