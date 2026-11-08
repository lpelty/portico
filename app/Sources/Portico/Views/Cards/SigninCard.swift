import AppKit
import SwiftUI

/// v0.25 §4.2 (ZE3): the chat's sign-in card, docked above the composer
/// while the gateway waits for the person to sign in again.
struct SigninDock: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let wait = model.signinWaits[chat] {
            if model.signinContinuing[chat] != nil || wait.state == .current {
                SigninContinuing()
            } else {
                SigninCard(
                    wait: wait,
                    accent: model.brand.accent ?? Theme.accent,
                    open: { model.openSignin(chat: chat) },
                    stop: { model.stopSignin(chat: chat) },
                    submit: { model.sendSigninCode(chat: chat, code: $0) })
            }
        }
    }
}

/// The waiting card: the key and the title, the gateway's words, then the
/// waiting line with Trouble signing in?, Don't wait and Open sign-in page.
/// The × is Don't wait too (ruling 12).
struct SigninCard: View {
    let wait: SigninWait
    let accent: Color
    let open: () -> Void
    let stop: () -> Void
    let submit: (String) -> Void
    @State private var folded = true

    var body: some View {
        DockedCard(
            title: wait.title, icon: ("key", Theme.wait), closeHelp: SigninPresentation.dontWaitTitle, titleLines: 2,
            onClose: stop
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(wait.body)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                if !folded, SigninPresentation.offersTrouble(wait) {
                    SigninFold(wait: wait, accent: accent, submit: submit)
                }
                footer
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(wait.title)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TimelineView(.everyMinute) { context in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(SigninPresentation.waitingLine(wait, now: context.date))
                        .scaledFont(12)
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if SigninPresentation.offersTrouble(wait) {
                Button(folded ? SigninPresentation.troubleTitle : SigninPresentation.hideTitle) { folded.toggle() }
                    .buttonStyle(.plain)
                    .scaledFont(12)
                    .foregroundStyle(accent)
                    .pointerStyle(.link)
            }
            Button(SigninPresentation.dontWaitTitle, action: stop)
                .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
            if SigninPresentation.showsOpen(wait) {
                Button(SigninPresentation.openTitle, action: open)
                    .buttonStyle(PillButtonStyle(kind: .primary(accent), compact: true))
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Trouble signing in? (§4.6): the link with Copy and Open, then the code
/// with Copy (AWS shows one), or a field that pastes the browser's code
/// into the sign-in command (Claude asks for one). A solid surface box.
struct SigninFold: View {
    let wait: SigninWait
    let accent: Color
    let submit: (String) -> Void
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let intro = SigninPresentation.foldIntro(wait) {
                Text(intro)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text2)
            }
            if let url = wait.url {
                HStack(spacing: 6) {
                    Text(url)
                        .scaledFont(12)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    SmallCopyButton(text: url)
                    Button("Open") {
                        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                }
            }
            if let code = wait.code, !code.isEmpty {
                HStack(spacing: 8) {
                    Text("Code")
                        .scaledFont(12)
                        .foregroundStyle(Theme.text3)
                    Text(code)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    SmallCopyButton(text: code)
                }
            } else if wait.wantsCode == true {
                HStack(spacing: 6) {
                    TextField(SigninPresentation.pastePrompt, text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(12)
                        .onSubmit(send)
                    Button("Submit", action: send)
                        .buttonStyle(PillButtonStyle(kind: .primary(accent), compact: true))
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.borderSubtle, lineWidth: 1))
    }

    private func send() {
        let code = pasted
        pasted = ""
        submit(code)
    }
}

/// "Copy", reading "Copied" for a moment: the plain text on the pasteboard.
private struct SmallCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
    }
}

/// Signed in: the card collapses to a check and "Signed in. Continuing…" for a moment.
struct SigninContinuing: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(Theme.iconFont(13, weight: .medium))
                .foregroundStyle(Theme.working)
            Text(SigninPresentation.continuingText)
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

/// The quiet note where a paused turn carried on: "Continued after sign-in · 9:31 PM".
struct SigninContinuedLine: View {
    let at: Date?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(Theme.iconFont(11))
            Text(at.map { "\(SigninPresentation.continuedNote) · \(MessageTime.short($0))" } ?? SigninPresentation.continuedNote)
                .scaledFont(12)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.text3)
        .accessibilityElement(children: .combine)
    }
}
