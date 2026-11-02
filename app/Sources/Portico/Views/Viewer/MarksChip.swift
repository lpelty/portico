import SwiftUI

/// The marks chip in the viewer header (v0.14 §3.4, AK5): a dot in the
/// accent, the count in the header's current form and a chevron; a click
/// lists the marks. Shown only while the chat has marks.
struct MarksChip: View {
    let chat: Int
    @ObservedObject var store: MarkStore
    let agent: ViewerAgent
    let form: MarkStore.ChipForm
    let accent: Color
    @State private var open = false

    /// "4 marks on 2 pages, opens the list" (VoiceOver).
    static func spokenLabel(count: Int, pages: Int) -> String {
        "\(count) mark\(count == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s"), opens the list"
    }

    var body: some View {
        let list = store.marks[chat] ?? []
        Button {
            open.toggle()
        } label: {
            MarksChipLabel(text: store.chipText(chat: chat, form: form), open: open, accent: accent)
        }
        .buttonStyle(.hover)
        .fixedSize()
        .help("Marks: open the list")
        .accessibilityLabel(Self.spokenLabel(count: list.count, pages: Set(list.map(\.page)).count))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MarksList(chat: chat, store: store, agent: agent, accent: accent, onDone: { open = false })
        }
    }
}

/// The chip's face, also measured hidden in each form for `HeaderFit`.
struct MarksChipLabel: View {
    let text: String
    var open = false
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
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

/// The chip's list: the marks grouped by page, the page the viewer shows
/// first as "THIS PAGE"; a row goes to its mark (its page first, when it
/// is another), and "Clear all marks" takes them all away.
struct MarksList: View {
    let chat: Int
    @ObservedObject var store: MarkStore
    @ObservedObject var agent: ViewerAgent
    let accent: Color
    let onDone: () -> Void

    /// A row for VoiceOver (spec §6): "Mark 2, Start here, trail.html",
    /// the label when there is no note, and "not on the page now" when lost.
    static func spokenLabel(for mark: Mark) -> String {
        var parts = ["Mark \(mark.number)", mark.note.isEmpty ? mark.label : mark.note, mark.page.name]
        if !mark.found { parts.append("not on the page now") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let current = agent.currentPage
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.groups(chat: chat, current: current), id: \.page) { group in
                        let here = group.page == current
                        header(here ? "THIS PAGE" : group.page.name.uppercased(), aside: here ? nil : "choose one to go back")
                        ForEach(group.marks) { mark in
                            row(mark, here: here)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            Divider()
                .padding(.vertical, 4)
            Button {
                agent.clearMarks(chat: chat)
                onDone()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eraser")
                        .font(Theme.iconFont(12))
                        .frame(width: 18)
                    Text("Clear all marks")
                        .scaledFont(13)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
        }
        .padding(6)
        .frame(width: 340)
    }

    private func header(_ title: String, aside: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .scaledFont(10, weight: .semibold)
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let aside {
                Text(aside)
                    .scaledFont(10)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func row(_ mark: Mark, here: Bool) -> some View {
        Button {
            agent.goToMark(mark, chat: chat)
            onDone()
        } label: {
            HStack(spacing: 10) {
                Text("\(mark.number)")
                    .scaledFont(11, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(accent, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(mark.note.isEmpty ? mark.label : mark.note)
                        .scaledFont(13)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !mark.found {
                        Text("not on the page now")
                            .scaledFont(11)
                            .foregroundStyle(Theme.text3)
                    }
                }
                Spacer(minLength: 8)
                if !here {
                    Image(systemName: "arrow.uturn.backward")
                        .font(Theme.iconFont(11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
            }
            .opacity(mark.found ? 1 : 0.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(mark.label)
        .accessibilityLabel(Self.spokenLabel(for: mark))
    }
}
