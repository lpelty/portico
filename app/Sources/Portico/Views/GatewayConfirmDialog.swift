import SwiftUI

/// v0.8 decisions 3 and 4: Stop and Restart ask first while a turn is
/// running ("A turn is running in Session N. Restart anyway?"), and Restart
/// all services always asks. Built like W2's ask-to-log sheet: Cancel
/// (Esc) does nothing; the action (Return) goes ahead.
struct GatewayConfirmDialog: View {
    let confirmation: GatewayConfirmation
    @EnvironmentObject private var model: AppModel

    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(confirmation.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(confirmation.body)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 16)
                Button("Cancel") { model.answerConfirmation(false) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle) { model.answerConfirmation(true) }
                    .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    .keyboardShortcut(.defaultAction)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: Self.width)
        .background(Theme.panel)
    }
}

extension View {
    /// Present the confirmation in this window while the model asks one
    /// whose button was here (`place`).
    func gatewayConfirmDialog(_ model: AppModel, place: ConfirmPlace) -> some View {
        sheet(
            isPresented: Binding(
                get: { model.confirming?.place == place },
                set: { if !$0 { model.answerConfirmation(false) } }),
            content: {
                if let confirmation = model.confirming {
                    GatewayConfirmDialog(confirmation: confirmation)
                        .environmentObject(model)
                }
            })
    }
}
