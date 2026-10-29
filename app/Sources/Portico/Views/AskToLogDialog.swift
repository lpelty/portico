import SwiftUI

/// W2: New asks to log first, only when skipping the log would lose
/// something (the deployment logs and the session has unlogged work).
/// Cancel (Esc) keeps the session; Start without logging renews with
/// `log: false`; Log and start new (the default, Return) renews with
/// `log: true`. A sheet, so Return and Esc reach it whatever has focus.
struct AskToLogDialog: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    static func title(chat: Int) -> String { "Log Session \(chat) before starting a new one?" }
    static let body = "Logging saves what this session did, so the next one can pick up where it left off. If you skip it, the new session starts with no record of this one."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.title(chat: chat))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(Self.body)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { model.answerAskToLog(log: nil) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 16)
                Button("Start without logging") { model.answerAskToLog(log: false) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                Button("Log and start new") { model.answerAskToLog(log: true) }
                    .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.panel)
    }
}

extension View {
    /// Present W2 while the model is asking about a session.
    func askToLogDialog(_ model: AppModel) -> some View {
        sheet(
            isPresented: Binding(
                get: { model.askingToLog != nil },
                set: { if !$0 { model.answerAskToLog(log: nil) } }),
            content: {
                if let chat = model.askingToLog {
                    AskToLogDialog(chat: chat)
                        .environmentObject(model)
                }
            })
    }
}
