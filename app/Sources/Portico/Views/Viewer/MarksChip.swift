import SwiftUI

/// The marks chip in the viewer header (v0.14 §3.4, AK5; v0.26.5): a dot
/// in the accent (a crossed-out eye while the marks are hidden), the count
/// of this page's marks and a chevron; a click lists them. Shown only on a
/// page that has marks of its own.
struct MarksChip: View {
    let chat: Int
    @ObservedObject var store: MarkStore
    let agent: ViewerAgent
    let form: MarkStore.ChipForm
    let accent: Color
    @State private var open = false

    /// "3 marks on this page, hidden, opens the list" (VoiceOver).
    static func spokenLabel(count: Int, hidden: Bool) -> String {
        "\(count) mark\(count == 1 ? "" : "s") on this page, \(hidden ? "hidden, " : "")opens the list"
    }

    var body: some View {
        let page = store.current
        let hidden = page.map(store.isHidden) ?? false
        Button {
            open.toggle()
        } label: {
            MarksChipLabel(text: store.chipText(page: page, form: form), open: open, hidden: hidden, accent: accent)
        }
        .buttonStyle(.hover)
        .fixedSize()
        .tip("Marks: open the list")
        .accessibilityLabel(Self.spokenLabel(count: page.map { store.marks(on: $0).count } ?? 0, hidden: hidden))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MarksList(chat: chat, store: store, agent: agent, accent: accent, onDone: { open = false })
                .popoverSurface()
        }
    }
}

/// The chip's face, also measured hidden in each form for `HeaderFit`.
struct MarksChipLabel: View {
    let text: String
    var open = false
    var hidden = false
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            // The same 7-point slot either way, so the chip keeps its width.
            ZStack {
                if hidden {
                    Image(systemName: "eye.slash")
                        .font(Theme.iconFont(9, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .fixedSize()
                } else {
                    Circle().fill(accent)
                }
            }
            .frame(width: 7, height: 7)
            Text(text)
                .scaledFont(12, monospacedDigit: true)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(Theme.iconFont(9, weight: .semibold))
                .foregroundStyle(Theme.text3)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Theme.selected, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .fixedSize()
        .contentShape(Rectangle())
    }
}

/// The chip's list (v0.26.5): this page's marks under "THIS PAGE"; a row
/// goes to its mark. The bottom row hides or shows the marks on the left
/// and clears them on the right; Clear asks first, in the row's place.
struct MarksList: View {
    let chat: Int
    @ObservedObject var store: MarkStore
    let agent: ViewerAgent
    let accent: Color
    let onDone: () -> Void
    @State var asking = false

    /// A row for VoiceOver (spec §6): "Mark 2, Start here", the label when
    /// there is no note, and "not on the page now" when lost.
    static func spokenLabel(for mark: Mark) -> String {
        var parts = ["Mark \(mark.number)", mark.note.isEmpty ? mark.label : mark.note]
        if !mark.found { parts.append("not on the page now") }
        return parts.joined(separator: ", ")
    }

    /// "Clear the 3 marks on this page?"
    static func question(count: Int) -> String {
        count == 1 ? "Clear the mark on this page?" : "Clear the \(count) marks on this page?"
    }

    var body: some View {
        let page = store.current
        let list = page.map(store.marks(on:)) ?? []
        let hidden = page.map(store.isHidden) ?? false
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header("THIS PAGE")
                    ForEach(list) { mark in
                        row(mark, hidden: hidden)
                    }
                }
            }
            .frame(maxHeight: 360)
            Divider()
                .padding(.vertical, 4)
            if asking {
                confirmation(count: list.count)
            } else {
                actions(hidden: hidden)
            }
        }
        .padding(6)
        .frame(width: 340)
    }

    private func actions(hidden: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                agent.setMarksHidden(!hidden)
            } label: {
                action(hidden ? "Show marks" : "Hide marks", icon: hidden ? "eye" : "eye.slash", colour: Theme.text)
            }
            .buttonStyle(.hover)
            Spacer(minLength: 8)
            Button {
                asking = true
            } label: {
                action("Clear marks", icon: "eraser", colour: Theme.deny)
            }
            .buttonStyle(.hover)
        }
    }

    private func action(_ title: String, icon: String, colour: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Theme.iconFont(12))
                .frame(width: 18)
            Text(title)
                .scaledFont(13)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func confirmation(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.question(count: count))
                .scaledFont(13, weight: .medium)
                .foregroundStyle(Theme.text)
            Text("The agent would have to mark them again.")
                .scaledFont(12)
                .foregroundStyle(Theme.text2)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { asking = false }
                    .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Clear marks") {
                    agent.clearMarks()
                    onDone()
                }
                .buttonStyle(PillButtonStyle(kind: .primary(Theme.deny), compact: true))
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .scaledFont(10, weight: .semibold)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func row(_ mark: Mark, hidden: Bool) -> some View {
        Button {
            // Going to a mark shows the page's marks: there is nothing to go to otherwise.
            agent.setMarksHidden(false)
            agent.goToMark(mark, chat: chat)
            onDone()
        } label: {
            HStack(spacing: 10) {
                Text("\(mark.number)")
                    .scaledFont(11, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 18, height: 18)
                    .background(accent, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(mark.note.isEmpty ? mark.label : mark.note)
                        .scaledFont(13)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !mark.found, !hidden {
                        Text("not on the page now")
                            .scaledFont(11)
                            .foregroundStyle(Theme.text2)
                    }
                }
                Spacer(minLength: 8)
            }
            .opacity(hidden || !mark.found ? 0.5 : 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .tip(mark.label)
        .accessibilityLabel(Self.spokenLabel(for: mark))
    }
}

/// The chip measured hidden in each of its three forms, for `HeaderFit`;
/// the file header and the space header share it.
struct MarksChipMeasures: View {
    let chat: Int
    let marks: MarkStore
    let accent: Color
    let report: (MarkStore.ChipForm, CGFloat) -> Void

    var body: some View {
        ForEach([MarkStore.ChipForm.full, .short, .count], id: \.self) { form in
            MarksChipLabel(text: marks.chipText(page: marks.current, form: form), accent: accent)
                .headerMeasure { report(form, $0) }
        }
    }
}
