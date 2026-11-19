import SwiftUI

/// Share with team as one card in the conversation (v0.28, PORT-82; Bill's
/// ZJ7). Draft: the files, the note the agent wrote, what the check found,
/// Share, Edit note and Cancel, and the sentence that says what Share
/// starts. Shared: when, Show in Shared and Stop syncing. The same card,
/// changed in place; a cancelled one is not drawn.
struct TeamShareCardView: View {
    let card: TeamShareCard
    @EnvironmentObject private var model: AppModel
    @State private var editingNote = false
    @FocusState private var noteFocused: Bool

    private var session: TeamShareSession? { model.teamCardSessions[card.share] }
    private var accent: Color { model.brand.accent ?? Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 10) {
                files
                switch card.state {
                case .draft: draft
                case .shared: shared
                case .cancelled: EmptyView()
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: card.state == .shared ? "checkmark" : "person.2")
                .font(Theme.iconFont(12, weight: card.state == .shared ? .semibold : .regular))
                .foregroundStyle(card.state == .shared ? Theme.working : Theme.text2)
                .accessibilityHidden(true)
            Text(TeamShareCardPresentation.title)
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(Theme.text)
            Text("· \(card.state == .shared ? TeamShareCardPresentation.sharedWord : TeamShareCardPresentation.draftWord)")
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var files: some View {
        VStack(spacing: 6) {
            ForEach(card.paths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: FileIcon.systemName(for: path))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 16)
                    Text(TeamShareSession.name(path))
                        .scaledFont(13)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(TeamShareSession.folder(path))
                        .scaledFont(11)
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
    }

    // MARK: Draft

    @ViewBuilder
    private var draft: some View {
        if let session {
            if editingNote {
                TextField("Note", text: noteBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .scaledFont(13)
                    .lineLimit(2...5)
                    .padding(8)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .focused($noteFocused)
                    .onSubmit { editingNote = false }
                    .accessibilityLabel("Note")
            } else if let note = TeamShareCardPresentation.quoted(session.note) {
                Text(note)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let title = session.findingsTitle {
                TeamShareFindings(session: session, title: title) { finding, choice in
                    model.teamCardChoose(card.share, finding, choice)
                }
            }
            if let error = session.checkError {
                TeamShareNotice(text: error)
            }
            if let refusal = session.refusal, refusal != session.checkError {
                TeamShareNotice(text: refusal)
            }
            HStack(spacing: 8) {
                Button(session.shareLabel) {
                    editingNote = false
                    model.teamCardSend(card.share)
                }
                .buttonStyle(PillButtonStyle(kind: .primary(accent)))
                .disabled(!session.canShare || session.draft == nil)
                .lineLimit(1)
                .fixedSize()
                Button {
                    editingNote.toggle()
                    if editingNote { DispatchQueue.main.async { noteFocused = true } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text(editingNote ? "Done" : "Edit note")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .disabled(session.sending)
                Button("Cancel") { model.teamCardCancel(card.share) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .disabled(session.sending)
            }
            .disabled(model.connection != .connected)
            Text(TeamShareCardPresentation.startsLine)
                .scaledFont(12)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { model.teamCardSessions[card.share]?.note ?? "" },
            set: { model.teamCardSetNote(card.share, $0) })
    }

    // MARK: Shared

    @ViewBuilder
    private var shared: some View {
        TimelineView(.everyMinute) { context in
            Text(TeamShareCardPresentation.sharedLine(at: card.at, now: context.date))
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            Button { model.teamShowShared() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                    Text("Show in Shared")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            // Stop syncing while any of the card's files is still shared; the card reads Shared either way.
            if !model.teamCardFiles(card).isEmpty {
                Button("Stop syncing") { model.teamCardStop(card) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .disabled(model.connection != .connected)
            }
        }
    }
}

/// What the check for personal material found, each with its choice
/// (v0.27, ZJ2): shared by the dialog and the card in a conversation.
struct TeamShareFindings: View {
    let session: TeamShareSession
    let title: String
    let choose: (String, TeamShareSession.Choice?) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.iconFont(12))
                    .foregroundStyle(Theme.wait)
                Text(title)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
            }
            ForEach(session.findings) { finding in
                if let choice = session.choices[finding.id] {
                    HStack(spacing: 6) {
                        Text(TeamShareSession.chosen(finding, choice))
                            .scaledFont(12)
                            .foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Undo") { choose(finding.id, nil) }
                            .buttonStyle(.plain)
                            .scaledFont(12)
                            .foregroundStyle(model.brand.accent ?? Theme.accent)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(TeamShareSession.text(finding)) \(TeamShareSession.changesFile)")
                            .scaledFont(12)
                            .lineSpacing(3)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Take it out") { choose(finding.id, .takeOut) }
                                .buttonStyle(PillButtonStyle(kind: .quiet))
                            Button("Keep it") { choose(finding.id, .keep) }
                                .buttonStyle(PillButtonStyle(kind: .quiet))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.waitSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One plain line on the amber ground: a check that could not finish, a share that was refused.
struct TeamShareNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.iconFont(12))
                .foregroundStyle(Theme.wait)
            Text(text)
                .scaledFont(12)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.waitSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
