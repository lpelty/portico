import AppKit
import PDFKit
import SwiftUI

// MARK: - ArtifactPresentation

/// How an artifact reads in the viewer and the history: its title, kind
/// word, where "Open externally" sends it, and (for a file) its URL.
struct ArtifactPresentation: Equatable {
    let artifact: Artifact

    init(artifact: Artifact) {
        self.artifact = artifact
    }

    /// The gateway's title, or the location's last component when blank.
    var title: String {
        let trimmed = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if artifact.kind == .url { return artifact.location }
        return URL(fileURLWithPath: artifact.location).lastPathComponent
    }

    /// The media kind, in the protocol's word.
    var kindLabel: String { artifact.media.rawValue }

    /// The file on disk, for file artifacts; `nil` for a URL.
    var fileURL: URL? {
        artifact.kind == .url ? nil : URL(fileURLWithPath: artifact.location)
    }

    /// What the system opens: the URL itself, or the file.
    var externalURL: URL? {
        if artifact.kind == .url { return URL(string: artifact.location) }
        return fileURL
    }

    /// The second line in the history: the path, or the URL.
    var subtitle: String { artifact.location }

    var systemImage: String {
        switch artifact.media {
        case .markdown: "doc.richtext"
        case .image: "photo"
        case .html: "globe"
        case .pdf: "doc.text"
        case .text: "doc.plaintext"
        case .url: "link"
        case .other: "doc"
        }
    }

    func openExternally() {
        guard let url = externalURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - ViewerView

/// The right column: the current artifact full size under a title bar.
/// The title is a menu of everything made in this session, with a count
/// (V2/V3); then Open externally, Focus (⌘⇧↩) and collapse.
struct ViewerView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel
    @State private var menuOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.panel)
    }

    private var made: [Artifact] { model.history(for: chat) }

    private var header: some View {
        HStack(spacing: 8) {
            titleMenu
            Spacer(minLength: 8)
            if let current = model.current[chat] {
                Button {
                    ArtifactPresentation(artifact: current).openExternally()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Open externally")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 9)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
            }
            focusButton
            Button {
                model.setViewer(visible: false, for: chat)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help("Collapse the viewer")
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    private var focusButton: some View {
        let on = model.isFocused(chat: chat)
        let accent = model.brand.accent ?? Theme.accent
        return Button {
            model.toggleFocus(chat: chat)
        } label: {
            Image(systemName: on ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? accent : Theme.text2)
                .frame(width: 24, height: 24)
                .background(on ? accent.opacity(0.15) : Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(on ? accent : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .help(on ? "Back to the usual layout (⌘⇧↩)" : "Focus on this: hide the sidebar and widen the viewer (⌘⇧↩)")
        .accessibilityLabel(on ? "Leave focus" : "Focus")
    }

    /// The title, with the count of things made here and a chevron; a
    /// click lists them, the one shown checked.
    private var titleMenu: some View {
        Button {
            menuOpen.toggle()
        } label: {
            HStack(spacing: 7) {
                if let current = model.current[chat] {
                    let shown = ArtifactPresentation(artifact: current)
                    Image(systemName: shown.systemImage)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                    Text(shown.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(made.isEmpty ? "Viewer" : model.madeHereLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                }
                if !made.isEmpty {
                    Text("\(made.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.surface, in: Capsule())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .disabled(made.isEmpty)
        .help(model.current[chat].map { "\(ArtifactPresentation(artifact: $0).kindLabel) · \($0.location)" } ?? model.madeHereLabel)
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            ArtifactMenu(chat: chat, artifacts: made, onPick: { menuOpen = false })
        }
    }

    @ViewBuilder
    private var content: some View {
        if let current = model.current[chat] {
            ArtifactContent(artifact: current)
                .id(current.id)
        } else {
            ContentUnavailableView(
                "Nothing open", systemImage: "rectangle.on.rectangle",
                description: Text(made.isEmpty ? "What the agent makes opens here." : "Pick something from the menu above."))
        }
    }
}

/// The viewer title's menu: everything made in this session, newest
/// first. A pick shows it; every row can open externally.
struct ArtifactMenu: View {
    let chat: Int
    let artifacts: [Artifact]
    let onPick: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.madeHereLabel.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(artifacts, id: \.id) { artifact in
                        row(artifact)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(6)
        .frame(width: 340)
    }

    private func row(_ artifact: Artifact) -> some View {
        let shown = ArtifactPresentation(artifact: artifact)
        let isCurrent = model.current[chat]?.id == artifact.id
        return Button {
            model.show(artifact, in: chat)
            onPick()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: shown.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shown.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(shown.kindLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.brand.accent ?? Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isCurrent ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(shown.subtitle)
        .contextMenu {
            Button("Open externally") { shown.openExternally() }
        }
    }
}

// MARK: - ArtifactContent

/// The artifact itself, by media kind.
struct ArtifactContent: View {
    let artifact: Artifact

    private var shown: ArtifactPresentation { ArtifactPresentation(artifact: artifact) }

    var body: some View {
        switch artifact.media {
        case .markdown:
            if let file = shown.fileURL { WebPane(load: .markdown(file)) } else { OtherPane(shown: shown) }
        case .html:
            if let file = shown.fileURL { WebPane(load: .html(file)) } else { OtherPane(shown: shown) }
        case .url:
            if let url = shown.externalURL { WebPane(load: .url(url)) } else { OtherPane(shown: shown) }
        case .image:
            if let file = shown.fileURL { ImagePane(file: file, shown: shown) } else { OtherPane(shown: shown) }
        case .pdf:
            if let file = shown.fileURL { PDFPane(file: file) } else { OtherPane(shown: shown) }
        case .text:
            if let file = shown.fileURL { TextPane(file: file, shown: shown) } else { OtherPane(shown: shown) }
        case .other:
            OtherPane(shown: shown)
        }
    }
}

/// An image at its own size inside scroll views, centred when smaller.
struct ImagePane: View {
    let file: URL
    let shown: ArtifactPresentation

    var body: some View {
        if let image = NSImage(contentsOf: file) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: max(image.size.width, 1), maxHeight: max(image.size.height, 1))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            OtherPane(shown: shown, note: "The image could not be read.")
        }
    }
}

/// A PDF in PDFKit's view, continuous pages, fit to width.
struct PDFPane: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: file)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != file {
            view.document = PDFDocument(url: file)
        }
    }
}

/// Plain text, monospaced, selectable. Never auto-opens (spec §5.3), but
/// readable here once picked from the viewer's menu.
struct TextPane: View {
    let file: URL
    let shown: ArtifactPresentation

    var body: some View {
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else {
            OtherPane(shown: shown, note: "The file could not be read as text.")
        }
    }
}

/// What the viewer cannot render: the path and Open externally.
struct OtherPane: View {
    let shown: ArtifactPresentation
    var note: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: shown.systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(shown.title)
                .font(.headline)
            Text(shown.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open externally") { shown.openExternally() }
                .pointerStyle(.link)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
