import AppKit
import SwiftUI

/// Everything the chat has produced, newest first. Picking a row shows it
/// in the viewer; every row can open externally in the system's app.
struct HistoryList: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: selection) {
            ForEach(model.history(for: chat), id: \.id) { artifact in
                HistoryRow(presentation: ArtifactPresentation(artifact: artifact))
                    .tag(artifact.id)
                    .contextMenu {
                        Button("Open externally") { ArtifactPresentation(artifact: artifact).openExternally() }
                    }
            }
        }
        .listStyle(.inset)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.current[chat]?.id },
            set: { id in
                guard let id, let artifact = model.artifacts[chat]?.first(where: { $0.id == id }) else { return }
                model.show(artifact, in: chat)
            })
    }
}

/// One history row: the kind's icon, the title, the location, and an
/// open-externally button.
struct HistoryRow: View {
    let presentation: ArtifactPresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .lineLimit(1)
                Text(presentation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                presentation.openExternally()
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Open externally")
        }
        .padding(.vertical, 2)
    }
}
