import SwiftUI

/// Share with team (v0.27, Bill's ZJ2): the files, an optional note, what
/// the check for personal material found, and the one sentence that says
/// what Share starts. A sheet, so Return and Esc reach it.
struct TeamShareDialog: View {
    @EnvironmentObject private var model: AppModel

    static let width: CGFloat = 520

    var body: some View {
        if let session = model.teamShare {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(Theme.iconFont(13))
                        .foregroundStyle(Theme.text2)
                    Text(TeamShareSession.title)
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Theme.text)
                }
                VStack(spacing: 4) {
                    ForEach(session.paths, id: \.self) { path in
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Text("Note")
                        .scaledFont(13)
                        .foregroundStyle(Theme.text2)
                        .padding(.top, 6)
                    TextField("", text: noteBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .scaledFont(13)
                        .lineLimit(2...5)
                        .padding(8)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                        .accessibilityLabel("Note")
                }
                Text(TeamShareSession.noteCaption)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
                if let title = session.findingsTitle {
                    TeamShareFindings(session: session, title: title) { model.teamShareChoose($0, $1) }
                }
                if let error = session.checkError {
                    TeamShareNotice(text: error)
                }
                if let refusal = session.refusal, refusal != session.checkError {
                    TeamShareNotice(text: refusal)
                }
                HStack(alignment: .center, spacing: 12) {
                    Text(TeamShareSession.footer)
                        .scaledFont(11)
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Cancel") { model.teamShareCancel() }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .keyboardShortcut(.cancelAction)
                        .disabled(session.sending)
                    Button(session.shareLabel) { model.teamShareSend() }
                        .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!session.canShare || session.draft == nil)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: Self.width)
            .background(Theme.panel)
        }
    }

    private var noteBinding: Binding<String> {
        Binding(get: { model.teamShare?.note ?? "" }, set: { model.teamShare?.note = $0 })
    }
}

extension View {
    /// Present Share with team while the model has a share open.
    func teamShareDialog(_ model: AppModel) -> some View {
        sheet(
            isPresented: Binding(
                get: { model.teamShare != nil },
                set: { if !$0 { model.teamShareCancel() } }),
            content: {
                TeamShareDialog()
                    .environmentObject(model)
            })
    }
}
