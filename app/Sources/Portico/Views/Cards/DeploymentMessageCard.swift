import SwiftUI

/// v0.22 (S3): the deployment's messages, docked above the message box in
/// the place and style of the question and permission cards. Up to three,
/// newest at the bottom, with "N more" above them when more wait. Each has
/// its title (bold), its text as Markdown, Dismiss, and Open when it names
/// a space. Held by the model while a reply streams in the open chat.
struct DeploymentMessageDock: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let docked = model.dockedDeploymentMessages
        if !docked.shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let more = DeploymentMessagePresentation.moreText(docked.more) {
                    Text(more)
                        .scaledFont(12)
                        .foregroundStyle(Theme.text2)
                        .padding(.leading, 4)
                }
                ForEach(docked.shown) { message in
                    DeploymentMessageCard(
                        message: message, fallbackTitle: model.brand.name,
                        accent: model.brand.accent ?? Theme.accent,
                        canOpen: message.space.map { id in model.spaces.contains { $0.id == id } } ?? false,
                        dismiss: { model.dismissDeploymentMessage(message.id) },
                        open: { model.openDeploymentMessage(message.id) })
                }
            }
        }
    }
}

/// One message in the `DockedCard` frame.
struct DeploymentMessageCard: View {
    let message: DeploymentMessage
    /// The title when the message has none: the brand's name.
    let fallbackTitle: String
    let accent: Color
    /// The message names a space that is listed.
    let canOpen: Bool
    let dismiss: () -> Void
    let open: () -> Void

    private var title: String {
        message.title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
    }

    var body: some View {
        DockedCard(title: title, closeHelp: "Dismiss", titleLines: 2, onClose: dismiss) {
            VStack(alignment: .leading, spacing: 10) {
                MarkdownText(text: message.text)
                    .padding(.horizontal, 4)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                    if message.space != nil {
                        Button("Open", action: open)
                            .buttonStyle(PillButtonStyle(kind: .primary(accent), compact: true))
                            .disabled(!canOpen)
                            .tip(canOpen ? "Open the space" : "That space isn't listed")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
