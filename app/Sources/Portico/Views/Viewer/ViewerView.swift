import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// A space's own front-matter keys are not shown as Properties (spec 4.3).
    var hiddenFrontMatterKeys: Set<String> {
        artifact.id.hasPrefix(AppModel.spaceArtifactPrefix) ? SpacesPresentation.hiddenFrontMatterKeys : []
    }

    /// The media kind, in the protocol's word.
    var kindLabel: String { artifact.media.rawValue }

    /// How the viewer draws it: the gateway's media, except that a file a
    /// pre-0.5 gateway called `other` but the app knows as text (`app.py`,
    /// `q3.csv`) draws as text, so an older gateway gets the new panes too.
    var media: Media {
        guard artifact.media == .other, artifact.kind != .url else { return artifact.media }
        return Media.of(path: artifact.location) == .text ? .text : .other
    }

    /// The file's extension, lowercased; empty for a URL.
    var fileExtension: String { fileURL?.pathExtension.lowercased() ?? "" }

    /// The separator when the file is a table (`csv`, `tsv`); else `nil`.
    var tableSeparator: Character? {
        media == .text ? DelimitedTable.separator(forExtension: fileExtension) : nil
    }

    /// A file artifact whose file is gone: the write was declined, or the
    /// file was moved or deleted after it was made.
    var isMissing: Bool {
        guard let fileURL else { return false }
        return !FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// What the viewer keys its pane on: the artifact's id, plus the file's
    /// modification date and size. A file opened from the Files pane keeps
    /// one id however often it is opened, and the agent can rewrite a file
    /// that is on screen; with the date in the key, a re-open or the next
    /// redraw after a change on disk loads it afresh instead of showing what
    /// was read the first time.
    var contentIdentity: String {
        guard let fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return artifact.id
        }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(artifact.id)|\(date)|\(size)"
    }

    /// The path the way a person writes it, with `~` for the home folder.
    var displayPath: String {
        fileURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? artifact.location
    }

    /// The app macOS would open it in ("Pages"), or `nil` when none.
    var defaultAppName: String? {
        guard let url = externalURL else { return nil }
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? UTType(filenameExtension: fileExtension).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        guard let app else { return nil }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The Open button's words: named for the app when there is one.
    var openLabel: String { defaultAppName.map { "Open in \($0)" } ?? "Open externally" }

    /// The kind in a sentence, plural: "Portico can't show <kind> here."
    var kindPhrase: String { Self.kindPhrase(forExtension: fileExtension) }

    /// The system's name for the file type, made plural ("Zip archive" →
    /// "Zip archives"); "DOCX files" when the system has no name for it;
    /// "this kind of file" with no extension at all.
    static func kindPhrase(forExtension ext: String) -> String {
        guard !ext.isEmpty else { return "this kind of file" }
        if let common = commonKinds[ext.lowercased()] { return common }
        if let type = UTType(filenameExtension: ext), !type.isDynamic,
           let name = type.localizedDescription, !name.isEmpty {
            return name.hasSuffix("s") ? name : name + "s"
        }
        return ext.uppercased() + " files"
    }

    /// The words people use for the usual office and archive files; the
    /// system's own names for these read like specifications ("Office Open
    /// XML word processing documents").
    static let commonKinds: [String: String] = [
        "doc": "Word documents", "docx": "Word documents",
        "xls": "Excel spreadsheets", "xlsx": "Excel spreadsheets",
        "ppt": "PowerPoint presentations", "pptx": "PowerPoint presentations",
        "pages": "Pages documents", "numbers": "Numbers spreadsheets", "key": "Keynote presentations",
        "zip": "ZIP archives", "gz": "compressed files", "tar": "archives",
        "mp4": "videos", "mov": "videos", "mp3": "audio files", "wav": "audio files", "m4a": "audio files",
    ]

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
        if tableSeparator != nil { return "tablecells" }
        return switch media {
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
/// (V2/V3); then Open in Obsidian (a file in a vault, v0.11 item 69), Open
/// externally, Focus (⌘⇧↩) and collapse.
struct ViewerView: View {
    let chat: Int
    /// The marks store, observed so the chip comes and goes (v0.14).
    @ObservedObject var marks: MarkStore
    @EnvironmentObject private var model: AppModel
    @State private var menuOpen = false
    /// The header's width and its parts' ideal widths, for `HeaderFit`.
    @State private var headerWidth: CGFloat?
    @State private var measured = HeaderFit.Widths.zero
    /// The vault the shown file is in, looked up once per file.
    @State private var vault: String?
    /// Where the page has gone when a link left the file (v0.13, AL4).
    @StateObject private var page = ViewerPageAddress()
    /// The Edit switch and the file being edited (v0.20 §2.2).
    @StateObject private var edit = ViewerEdit()
    /// v0.23: the comments margin for the shown Markdown file.
    @StateObject private var comments = ViewerComments()

    var body: some View {
        let app = model.viewerApp[chat].flatMap { model.app(forToolUse: $0) }
        // v0.18 (ruling 36): an app's copy over the file view, which stays
        // alive under it, so X shows the file again as it was.
        ZStack {
            fileView
                .opacity(app == nil ? 1 : 0)
                .allowsHitTesting(app == nil)
                .accessibilityHidden(app != nil)
            if let app {
                AppViewerPane(chat: chat, state: app)
            }
        }
    }

    private var fileView: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { ViewerActingGlow(agent: model.viewerAgent, chat: chat, accent: model.brand.accent ?? Theme.accent) }
                .environment(\.viewerPageAddress, page)
                .onChange(of: model.current[chat]?.location) { page.outside = nil }
        }
        .background(Theme.panel)
        // Edit is off at every open; another file (or none) saves the old
        // one, and a file whose edits are still unsaved comes back in Edit.
        .onChange(of: model.current[chat]?.location) { _, location in edit.shown(location) }
        .onChange(of: commentsFile, initial: true) { _, file in syncComments(); comments.show(file: file) }
        .onChange(of: model.hello) { syncComments(); comments.push() }
        .onChange(of: commentsReadOnly, initial: true) { _, reason in comments.readOnly = reason; comments.push() }
        .onAppear {
            edit.chat = chat
            ViewerEditing.shared.register(edit, chat: chat)
            edit.shown(model.current[chat]?.location)
        }
        .onChange(of: chat) { _, chat in
            edit.shown(nil)
            edit.chat = chat
            ViewerEditing.shared.register(edit, chat: chat)
            edit.shown(model.current[chat]?.location)
        }
        // The viewer hidden or gone: the edit is ended (the registry keeps
        // text that couldn't be saved).
        .onDisappear { edit.shown(nil) }
        // The agent may have written the file (§2.6): an artifact event or
        // any redraw that sees a new date or size.
        .onChange(of: editedFileIdentity) { _, identity in
            guard identity != nil, let session = edit.session else { return }
            Task { await session.recheckDisk() }
        }
    }

    /// v0.23: the Markdown file the comments are for, when the toggle shows.
    private var commentsFile: URL? {
        guard page.outside == nil, let current = model.current[chat] else { return nil }
        let shown = ArtifactPresentation(artifact: current)
        let isSpace = model.spaces.contains { $0.location == current.location }
        guard !shown.isMissing, ViewerCommentsToggle.shows(media: shown.media, isSpace: isSpace) else { return nil }
        return shown.fileURL
    }

    /// Why comments can't be written for the shown file (it's read-only), else nil.
    private var commentsReadOnly: String? {
        if case .readOnly(let reason) = editability { return reason }
        return nil
    }

    private func syncComments() {
        comments.onWritten = { [weak model, chat] url in model?.fileEdited(path: url.path, chat: chat) }
        comments.chat = chat
        comments.focus = model
        comments.helloPersonName = model.hello?.person?.name
        comments.agentName = model.hello?.brand.agentName ?? "Agent"
        comments.accentHex = model.hello?.brand.accent
    }

    /// The edited file's date and size, while Edit is on.
    private var editedFileIdentity: String? {
        guard let session = edit.session, let current = model.current[chat], current.location == session.location else {
            return nil
        }
        return ArtifactPresentation(artifact: current).contentIdentity + "|" + current.id
    }

    /// The shown file's editability, for the toggle; `nil` with no file
    /// on disk (or a page a link went to).
    private var editability: Editability? {
        guard page.outside == nil, let current = model.current[chat] else { return nil }
        let shown = ArtifactPresentation(artifact: current)
        guard !shown.isMissing else { return nil }
        // One session per file: another viewer's edit makes this one read-only.
        if !edit.isEditing, edit.editedElsewhere(current.location) { return .readOnly(reason: ViewerEdit.elsewhere) }
        return FileEditing.editability(for: shown)
    }

    /// The Edit toggle and the save state, while there is a file to edit.
    @ViewBuilder
    private var editControls: some View {
        if let editability {
            HStack(spacing: 8) {
                if let session = edit.session {
                    ViewerEditStatus(session: session, onDiscard: { Task { await edit.discard() } })
                } else if let note = edit.note {
                    Text(note)
                        .scaledFont(12)
                        .foregroundStyle(Theme.deny)
                        .lineLimit(1)
                } else if let offer = edit.readOffer, editability.canEdit {
                    HStack(spacing: 4) {
                        Text(ViewerEdit.readOfferWords)
                            .scaledFont(12)
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                        Button(ViewerEdit.readOfferAction) {
                            Task { await edit.restoreFromReadMode(model.current[chat]) }
                        }
                        .buttonStyle(.link)
                        .scaledFont(12, weight: .semibold)
                        .fixedSize()
                    }
                    .tip("Edits from \(offer.date.formatted(date: .abbreviated, time: .shortened)) weren't saved; "
                        + "Restore turns Edit on and puts them back (⌘Z undoes it)")
                }
                if commentsFile != nil {
                    ViewerCommentsToggle(on: comments.shown, count: comments.openCount, focused: model.isFocused(chat: chat),
                                         accent: model.brand.accent ?? Theme.accent) {
                        syncComments()
                        comments.setShown(!comments.shown, chat: chat, focus: model)
                    }
                }
                ViewerEditToggle(on: edit.isEditing, editability: editability,
                                 accent: model.brand.accent ?? Theme.accent) {
                    edit.toggle(model.current[chat])
                }
            }
        }
    }

    private var made: [Artifact] { model.history(for: chat) }

    private var header: some View { fileHeader }

    private var chipShown: Bool { !(marks.marks[chat] ?? []).isEmpty }

    /// The measured parts as `HeaderFit` counts them, with the header's
    /// spacing: padding 16 + 16, 8 either side of the Spacer and its 8,
    /// Focus 24 and collapse 20 each after 8; the chip and the buttons
    /// each after 8 when they are there; the note after the title's 7.
    private var fitWidths: HeaderFit.Widths {
        let chip = chipShown
        let spaced = { (width: CGFloat) in width > 0 ? width + 8 : 0 }
        return HeaderFit.Widths(
            title: measured.title,
            note: page.outside != nil ? measured.note + 7 : 0,
            chipFull: chip ? spaced(measured.chipFull) : 0,
            chipShort: chip ? spaced(measured.chipShort) : 0,
            chipCount: chip ? spaced(measured.chipCount) : 0,
            buttonsLabelled: spaced(measured.buttonsLabelled),
            buttonsIcons: spaced(measured.buttonsIcons),
            fixed: 32 + 8 + 8 + (8 + ViewerHeader.buttonHeight) + (8 + ViewerHeader.buttonHeight),
            edit: editability != nil ? measured.edit + 8 : 0)
    }

    private var fileHeader: some View {
        let fit = HeaderFit.step(available: headerWidth, fitWidths)
        return HStack(spacing: 8) {
            titleMenu(fit)
            Spacer(minLength: 8)
            if chipShown {
                MarksChip(chat: chat, store: marks, agent: model.viewerAgent, form: fit.chipForm,
                          accent: model.brand.accent ?? Theme.accent)
            }
            editControls
            openButtons(labelled: fit.labelled)
            focusButton
            ViewerCloseButton(help: "Close the viewer", label: "Close the viewer") {
                model.closeFile(in: chat)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
        .background { fileHeaderMeasures }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
        .task(id: model.current[chat]?.location) {
            vault = model.current[chat].flatMap { ArtifactPresentation(artifact: $0).fileURL }
                .flatMap { Obsidian.vault(containing: $0.path) }
        }
    }

    /// Hidden copies of the header's parts at their ideal widths.
    private var fileHeaderMeasures: some View {
        ZStack {
            titleLabel(note: false).headerMeasure { measured.title = $0 }
            if let outside = page.outside {
                noteText(outside).headerMeasure { measured.note = $0 }
            }
            if chipShown {
                MarksChipMeasures(chat: chat, marks: marks, accent: model.brand.accent ?? Theme.accent) { form, width in
                    measured.setChip(form, width)
                }
            }
            editControls
                .headerMeasure { measured.edit = $0 }
            HStack(spacing: 8) { openButtons(labelled: true) }
                .headerMeasure { measured.buttonsLabelled = $0 }
            HStack(spacing: 8) { openButtons(labelled: false) }
                .headerMeasure { measured.buttonsIcons = $0 }
        }
    }

    /// Open externally, and Open in Obsidian before it for a file in a
    /// vault; none for a file that isn't on disk (nothing to open).
    @ViewBuilder
    private func openButtons(labelled: Bool) -> some View {
        if let outside = page.outside {
            headerButton("Open externally", icon: .symbol("arrow.up.right"), labelled: labelled,
                         help: "Open \(ViewerPageAddress.display(outside)) in your browser") {
                NSWorkspace.shared.open(outside)
            }
        } else if let current = model.current[chat], !ArtifactPresentation(artifact: current).isMissing {
            let shown = ArtifactPresentation(artifact: current)
            if vault != nil, let path = shown.fileURL?.path, Obsidian.opens(path: path) {
                let installed = Obsidian.isInstalled
                headerButton("Open in Obsidian", icon: Obsidian.appIcon.map { .image($0) } ?? .symbol("diamond"),
                             labelled: labelled,
                             help: installed ? "Open this note in Obsidian" : Obsidian.notInstalledHelp) {
                    Obsidian.open(path: path)
                }
                .disabled(!installed)
            }
            headerButton("Open externally", icon: .symbol("arrow.up.right"), labelled: labelled,
                         help: shown.openLabel) {
                shown.openExternally()
            }
        }
    }

    private func headerButton(
        _ title: String, icon: ViewerHeaderIcon, labelled: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        ViewerHeaderButton(title: title, icon: icon, labelled: labelled, help: help, action: action)
    }

    private var focusButton: some View { ViewerFocusButton(chat: chat) }

    /// AL4: whether the agent may use the outside site, as the act rule has it.
    private func outsideNote(_ url: URL) -> String {
        ViewerPageAddress.note(for: url, actHosts: model.hello?.viewerDefaults?.actHosts ?? [])
    }

    private func noteText(_ outside: URL) -> some View {
        Text(outsideNote(outside))
            .scaledFont(12)
            .foregroundStyle(Theme.text3)
            .lineLimit(1)
    }

    /// The title, with the count of things made here and a chevron; a
    /// click lists them, the one shown checked. The outside note gives way
    /// first; the title keeps its room until the header's last step (AK5).
    private func titleMenu(_ fit: HeaderFit.Step) -> some View {
        Button {
            menuOpen.toggle()
        } label: {
            titleLabel(note: true)
        }
        .buttonStyle(.hover)
        .layoutPriority(fit < .titleShrinks ? 1 : 0)
        .disabled(made.isEmpty)
        .tip(model.current[chat].map { "\(ArtifactPresentation(artifact: $0).kindLabel) · \($0.location)" } ?? model.madeHereLabel)
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            ArtifactMenu(chat: chat, artifacts: made, onPick: { menuOpen = false })
                .popoverSurface()
        }
    }

    private func titleLabel(note: Bool) -> some View {
        HStack(spacing: 7) {
            if let outside = page.outside {
                Image(systemName: "globe")
                    .font(Theme.iconFont(13))
                    .foregroundStyle(Theme.text2)
                Text(ViewerPageAddress.display(outside))
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if note {
                    noteText(outside)
                        .layoutPriority(-1)
                }
            } else if let current = model.current[chat] {
                let shown = ArtifactPresentation(artifact: current)
                Image(systemName: shown.systemImage)
                    .font(Theme.iconFont(13))
                    .foregroundStyle(Theme.text2)
                Text(shown.title)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(made.isEmpty ? "Viewer" : model.madeHereLabel)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text2)
            }
            if !made.isEmpty {
                Text("\(made.count)")
                    .scaledFont(11, monospacedDigit: true)
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
                Image(systemName: "chevron.down")
                    .font(Theme.iconFont(9, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if let current = model.current[chat], let session = edit.session, edit.location == current.location {
            // While editing, the pane is keyed on the file alone: its own
            // saves change the date and size, and must not reload it.
            VStack(spacing: 0) {
                EditConflictBar(session: session)
                EditRestoreBar(edit: edit)
                EditorPaneHost(
                    settings: model.settings, session: session, topLine: edit.topLine(for: session.url),
                    onStop: { Task { await edit.turnOff() } },
                    onOpenFile: { [chat] path in model.reveal(file: path, in: chat) },
                    onCoordinator: { [edit] in edit.editor = $0 },
                    comments: comments)
                    .id("edit|\(current.location)|\(ObjectIdentifier(session).hashValue)")
            }
            // The editor's view, for the agent's look (v0.20 §4).
            .background { ViewerPaneAnchor(agent: model.viewerAgent) }
            .environment(\.viewerSlot, .work)
        } else if let current = model.current[chat] {
            ArtifactContent(artifact: current)
                // v0.23: a comment written here re-reads the page in place (paneRevision), keeping the reader's place.
                .id(comments.paneKey(ArtifactPresentation(artifact: current).contentIdentity))
                .environment(\.viewerAgent, model.viewerAgent)
                .environment(\.viewerSlot, .work)
                .environment(\.viewerComments, comments)
                .environment(\.webPaneRevision, comments.paneRevision)
        } else {
            ContentUnavailableView(
                "Nothing open", systemImage: "rectangle.on.rectangle",
                description: Text(made.isEmpty ? "What the agent makes opens here." : "Pick something from the menu above."))
        }
    }
}

/// The header's buttons share one glyph size and weight (v0.17 §3.5,
/// ruling 10): every glyph drawn in a 14 pt square.
enum ViewerHeader {
    static let iconSize: CGFloat = 12
    static let iconWeight: Font.Weight = .medium
    /// The square each button's glyph is drawn in.
    static let glyphSide: CGFloat = 14
    /// v0.22 item 23: every button in the row is this tall, icon-only
    /// (a square) or icon and words alike.
    static let buttonHeight: CGFloat = 24
}

/// A header button's glyph: an SF Symbol, or an app's own icon (Open in
/// Obsidian, read from the installed app).
enum ViewerHeaderIcon {
    case symbol(String)
    case image(NSImage)
}

/// One of the header's open buttons (AG2/AG2b): icon and words on a
/// control fill while the viewer is wide; the icon alone, its words in
/// the tooltip, when it is narrow.
struct ViewerHeaderButton: View {
    let title: String
    let icon: ViewerHeaderIcon
    let labelled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                glyph
                if labelled {
                    Text(title)
                        .scaledFont(12)
                }
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, labelled ? 9 : 5)
            .frame(minWidth: ViewerHeader.buttonHeight, minHeight: ViewerHeader.buttonHeight,
                   maxHeight: ViewerHeader.buttonHeight)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .tip(help)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(Theme.iconFont(ViewerHeader.iconSize, weight: ViewerHeader.iconWeight))
                .frame(width: ViewerHeader.glyphSide, height: ViewerHeader.glyphSide)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: ViewerHeader.glyphSide, height: ViewerHeader.glyphSide)
                .accessibilityHidden(true)
        }
    }
}

/// The Focus button (⌘⇧↩).
struct ViewerFocusButton: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let on = model.isFocused(chat: chat)
        let accent = model.brand.accent ?? Theme.accent
        Button {
            model.toggleFocus(chat: chat)
        } label: {
            Image(systemName: on ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(Theme.iconFont(ViewerHeader.iconSize, weight: ViewerHeader.iconWeight))
                .frame(width: ViewerHeader.glyphSide, height: ViewerHeader.glyphSide)
                .foregroundStyle(on ? accent : Theme.text2)
                .frame(width: ViewerHeader.buttonHeight, height: ViewerHeader.buttonHeight)
                .background(on ? Theme.accentSoft : Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(on ? accent : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .tip(on ? "Back to the usual layout (⌘⇧↩)" : "Widen the viewer (⌘⇧↩)")
        .accessibilityLabel(on ? "Back to the usual layout" : "Widen the viewer")
    }
}

/// The header's X: the file viewer's closes the file (v0.17 §3.4), a
/// space's goes back to Work.
struct ViewerCloseButton: View {
    let help: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(Theme.iconFont(ViewerHeader.iconSize, weight: ViewerHeader.iconWeight))
                .frame(width: ViewerHeader.glyphSide, height: ViewerHeader.glyphSide)
                .foregroundStyle(Theme.text2)
                .frame(width: ViewerHeader.buttonHeight, height: ViewerHeader.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .tip(help)
        .accessibilityLabel(label)
    }
}

/// The viewer column: an open space (it belongs to the window, so it shows
/// with no chat too), else the shown chat's viewer.
///
/// v0.14 test fix: the chat's viewer stays alive under an open space,
/// hidden and inert, rather than being taken down and made again. Its page
/// is the person's: going back to Work must not load it again (that lost
/// the scroll, what the person typed, and the refs of the agent's last
/// look). The agent acts in whichever is shown (`ViewerAgent.Slot`).
struct ViewerColumn: View {
    let chat: Int?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let spaceOpen = model.openSpace != nil
        ZStack {
            if let chat {
                ViewerView(chat: chat, marks: model.markStore)
                    .opacity(spaceOpen ? 0 : 1)
                    .allowsHitTesting(!spaceOpen)
                    // Its shortcuts (Focus, ⌘⇧↩) are the space's while one is open.
                    .disabled(spaceOpen)
                    .accessibilityHidden(spaceOpen)
            }
            if spaceOpen {
                SpaceViewer(chat: chat, marks: model.markStore)
            }
        }
    }
}

/// A space open (row AI2): its icon and title, "Updated <time>", then
/// Refresh (only when the gateway can), expand, and ×, which goes back to
/// Work and the file that was open before. Re-read when the gateway says
/// the file changed (`updated` advances).
struct SpaceViewer: View {
    let chat: Int?
    /// The marks store, observed so the chip comes and goes (v0.14).
    @ObservedObject var marks: MarkStore
    @EnvironmentObject private var model: AppModel
    @State private var headerWidth: CGFloat?
    @State private var measured = HeaderFit.Widths.zero
    /// Where the space's page has gone when a link left it (v0.15 §5.2).
    @StateObject private var page = ViewerPageAddress()

    var body: some View {
        VStack(spacing: 0) {
            if let space = model.openSpace.flatMap({ id in model.spaces.first { $0.id == id } }) {
                header(space)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if let artifact = model.openSpaceArtifact {
                // Kept for the space (not re-made on each change, which lost
                // the scroll position); a change re-reads it in place.
                ArtifactContent(artifact: artifact)
                    .id(artifact.id)
                    .environment(\.webPaneRevision, ArtifactPresentation(artifact: artifact).contentIdentity + "|" + (model.openSpaceContentKey ?? ""))
                    .environment(\.viewerAgent, model.viewerAgent)
                    .environment(\.viewerSlot, .space)
                    .environment(\.viewerPageAddress, page)
                    // v0.22: the page's action links, and a notice's fragment.
                    .environment(\.spaceActionLink, spaceActionLink)
                    .environment(\.webPaneFragment, fragmentRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if let chat {
                            ViewerActingGlow(agent: model.viewerAgent, chat: chat, accent: model.brand.accent ?? Theme.accent)
                        }
                    }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.panel)
        // Another space (or the space's file replaced) starts at its own name.
        .onChange(of: model.openSpace) { page.outside = nil }
        .onChange(of: model.openSpaceArtifact?.id) { page.outside = nil }
    }

    /// The chat whose marks the chip counts; none without a chat.
    private var chipChat: Int? {
        guard let chat, !(marks.marks[chat] ?? []).isEmpty else { return nil }
        return chat
    }

    /// As `ViewerView.fitWidths`: the icon and title, "Updated" after 8,
    /// padding 16 + 16, 8 either side of the Spacer and its 8, × (24) after
    /// 8, Focus 24 after 8 with a chat, the chip and Refresh after 8 each.
    private var fitWidths: HeaderFit.Widths {
        let chip = chipChat != nil
        let spaced = { (width: CGFloat) in width > 0 ? width + 8 : 0 }
        return HeaderFit.Widths(
            title: measured.title,
            note: spaced(measured.note),
            chipFull: chip ? spaced(measured.chipFull) : 0,
            chipShort: chip ? spaced(measured.chipShort) : 0,
            chipCount: chip ? spaced(measured.chipCount) : 0,
            buttonsLabelled: action != nil ? spaced(measured.buttonsLabelled) : 0,
            buttonsIcons: action != nil ? spaced(measured.buttonsIcons) : 0,
            fixed: 32 + 8 + 8 + (8 + ViewerHeader.buttonHeight) + (chat != nil ? 8 + ViewerHeader.buttonHeight : 0))
    }

    /// The space's title, or, when a link left the space, the outside
    /// site's address in its place, as the Work viewer shows it (v0.15 §5.2).
    @ViewBuilder
    private func spaceTitle(_ space: SpaceInfo) -> some View {
        if let outside = page.outside {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(Theme.iconFont(13))
                    .foregroundStyle(Theme.text2)
                Text(ViewerPageAddress.display(outside))
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .tip(ViewerPageAddress.display(outside))
        } else {
            spaceName(space)
        }
    }

    private func spaceName(_ space: SpaceInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: space.icon)
                .font(Theme.iconFont(13))
                .foregroundStyle(Theme.text2)
            Text(space.title)
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// v0.22 (S1): a `space-action:` link clicked in the open space's page.
    private var spaceActionLink: ((URL) -> Void)? {
        guard let id = model.openSpace else { return nil }
        return { [model] url in model.spaceActionLinkActivated(url, space: id) }
    }

    /// v0.22 (S2): the notice's fragment, for this space only.
    private var fragmentRequest: WebPane.FragmentRequest? {
        guard let request = model.spaceScrollRequest, request.space == model.openSpace else { return nil }
        return WebPane.FragmentRequest(key: "\(request.serial)", fragment: request.fragment)
    }

    /// "· <full date and time>" (v0.22.1 item 26), "Refreshing…" (v0.22) or
    /// the last failure, or the outside note while the page is on another
    /// site (the note slot gives way the same either way).
    /// Pulls "· <date>" toward the title so the gap before the dot matches
    /// the space after it (v0.22.1).
    static let datedNoteNudge: CGFloat = -5

    private func updatedText(_ space: SpaceInfo) -> some View {
        let note = SpacesPresentation.headerNote(
            refreshing: model.isRefreshing(space.id), error: model.spaceErrors[space.id], updated: space.updatedDate)
        let text: String
        var failed = false
        switch note {
        case .updated(let words): text = words
        case .refreshing: text = SpacesPresentation.refreshingText
        case .error(let words): text = words; failed = true
        }
        let dated = page.outside == nil && note != .refreshing && !failed && !text.isEmpty
        return Text(page.outside.map { ViewerPageAddress.note(for: $0, actHosts: model.hello?.viewerDefaults?.actHosts ?? []) } ?? text)
            .scaledFont(12)
            // v0.22.1: the date's dot sits a space from the title, as it does
            // from the date, not the row's 8 pt.
            .padding(.leading, dated ? Self.datedNoteNudge : 0)
            .foregroundStyle(failed && page.outside == nil ? Theme.deny : Theme.text3)
            .lineLimit(1)
            .truncationMode(.tail)
            .tip(failed && page.outside == nil ? text : "")
    }

    /// The header's one button: Open externally while the page is on an
    /// outside site (as the Work viewer has it), else Refresh when the
    /// gateway can; none otherwise (v0.15 §5.2).
    enum HeaderAction: Equatable {
        case openExternally(URL)
        case refresh
    }

    static func headerAction(outside: URL?, canRefresh: Bool) -> HeaderAction? {
        if let outside { return .openExternally(outside) }
        return canRefresh ? .refresh : nil
    }

    private var action: HeaderAction? {
        Self.headerAction(outside: page.outside, canRefresh: model.spacesCanRefresh)
    }

    @ViewBuilder
    private func actionButton(_ action: HeaderAction, _ space: SpaceInfo, labelled: Bool) -> some View {
        switch action {
        case .openExternally(let url):
            ViewerHeaderButton(title: "Open externally", icon: .symbol("arrow.up.right"), labelled: labelled,
                               help: "Open \(ViewerPageAddress.display(url)) in your browser") {
                NSWorkspace.shared.open(url)
            }
        case .refresh:
            refreshButton(space, labelled: labelled)
        }
    }

    private func refreshButton(_ space: SpaceInfo, labelled: Bool) -> some View {
        ViewerHeaderButton(title: "Refresh", icon: .symbol("arrow.clockwise"), labelled: labelled, help: "Ask the agent to update this now") {
            model.refreshSpace(space.id)
        }
    }

    private func header(_ space: SpaceInfo) -> some View {
        let fit = HeaderFit.step(available: headerWidth, fitWidths)
        let accent = model.brand.accent ?? Theme.accent
        return HStack(spacing: 8) {
            spaceTitle(space)
                .layoutPriority(fit < .titleShrinks ? 1 : 0)
            updatedText(space)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            if let chipChat {
                MarksChip(chat: chipChat, store: marks, agent: model.viewerAgent, form: fit.chipForm, accent: accent)
            }
            if let action {
                actionButton(action, space, labelled: fit.labelled)
            }
            if let chat { ViewerFocusButton(chat: chat) }
            ViewerCloseButton(help: "Back to Work (⌘0)", label: "Close the space") {
                model.setOpenSpace(nil)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
        .background {
            ZStack {
                spaceTitle(space).headerMeasure { measured.title = $0 }
                updatedText(space).headerMeasure { measured.note = $0 }
                if let chipChat {
                    MarksChipMeasures(chat: chipChat, marks: marks, accent: accent) { form, width in
                        measured.setChip(form, width)
                    }
                }
                if let action {
                    actionButton(action, space, labelled: true).headerMeasure { measured.buttonsLabelled = $0 }
                    actionButton(action, space, labelled: false).headerMeasure { measured.buttonsIcons = $0 }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
    }

}

/// How the viewer header gives way as it narrows (v0.14 §3.4, AK5). Each
/// part's ideal width is measured; the first step whose need fits is the
/// one drawn. The need is title + note + chip + buttons + fixed, where the
/// buttons go to icons first, then the note gives up its room, then the
/// chip goes to "N marks" and to "N", and only then does the title shrink.
/// With no chip, the chip widths are 0.
enum HeaderFit {
    struct Widths: Equatable {
        var title, note, chipFull, chipShort, chipCount, buttonsLabelled, buttonsIcons, fixed: CGFloat
        /// The Edit toggle with the save state beside it (v0.20 §2.2); it
        /// keeps its room at every step.
        var edit: CGFloat = 0

        static let zero = Widths(title: 0, note: 0, chipFull: 0, chipShort: 0, chipCount: 0,
                                 buttonsLabelled: 0, buttonsIcons: 0, fixed: 0)

        mutating func setChip(_ form: MarkStore.ChipForm, _ width: CGFloat) {
            switch form {
            case .full: chipFull = width
            case .short: chipShort = width
            case .count: chipCount = width
            }
        }
    }

    enum Step: Int, Comparable {
        case full, buttonIcons, noteShrinks, chipShort, chipCount, titleShrinks

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Whether the open buttons keep their words.
        var labelled: Bool { self == .full }

        /// The chip's text at this step.
        var chipForm: MarkStore.ChipForm {
            switch self {
            case .full, .buttonIcons, .noteShrinks: return .full
            case .chipShort: return .short
            case .chipCount, .titleShrinks: return .count
            }
        }
    }

    static func step(available: CGFloat, _ w: Widths) -> Step {
        let tries: [(Step, CGFloat, CGFloat, CGFloat)] = [
            (.full, w.note, w.chipFull, w.buttonsLabelled),
            (.buttonIcons, w.note, w.chipFull, w.buttonsIcons),
            (.noteShrinks, 0, w.chipFull, w.buttonsIcons),
            (.chipShort, 0, w.chipShort, w.buttonsIcons),
            (.chipCount, 0, w.chipCount, w.buttonsIcons),
        ]
        for (step, note, chip, buttons) in tries where w.title + note + chip + buttons + w.fixed + w.edit <= available {
            return step
        }
        return .titleShrinks
    }

    /// A header not measured yet keeps its words.
    static func step(available: CGFloat?, _ w: Widths) -> Step {
        available.map { step(available: $0, w) } ?? .full
    }
}

extension View {
    /// A hidden copy of a header part at its ideal width, reporting that
    /// width (HeaderFit's measuring; placed in a `.background`).
    func headerMeasure(_ report: @escaping (CGFloat) -> Void) -> some View {
        fixedSize()
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report($0) }
    }
}

// MARK: - ArtifactContent

/// The artifact itself, by media kind. A file that is no longer on disk
/// says so first, whatever its kind.
struct ArtifactContent: View {
    let artifact: Artifact
    @Environment(\.viewerAgent) private var agent

    private var shown: ArtifactPresentation { ArtifactPresentation(artifact: artifact) }

    var body: some View {
        panes
            // A native pane's view, for the agent's look (v0.12).
            .background {
                if let agent, WebPane.Load(shown) == nil || shown.isMissing { ViewerPaneAnchor(agent: agent) }
            }
    }

    @ViewBuilder
    private var panes: some View {
        if shown.isMissing {
            MissingPane(shown: shown)
        } else {
            switch shown.media {
            case .markdown, .html, .url:
                if let load = WebPane.Load(shown) { WebPane(load: load) } else { OtherPane(shown: shown) }
            case .image:
                if let file = shown.fileURL { ImagePane(file: file, shown: shown) } else { OtherPane(shown: shown) }
            case .pdf:
                if let file = shown.fileURL { PDFPane(file: file) } else { OtherPane(shown: shown) }
            case .text:
                if let file = shown.fileURL {
                    if let separator = shown.tableSeparator {
                        TablePane(file: file, separator: separator, shown: shown)
                    } else {
                        TextPane(file: file, shown: shown)
                    }
                } else {
                    OtherPane(shown: shown)
                }
            case .other:
                OtherPane(shown: shown)
            }
        }
    }
}

/// An image, fit to the pane by default (never enlarged past 100%), with
/// the zoom control, pinch, keys and double-click (v0.20 §3.1).
struct ImagePane: View {
    let file: URL
    let shown: ArtifactPresentation
    @State private var scale: CGFloat = 1
    @State private var awake = true
    @State private var box = ImageZoomPane.ControllerBox()

    var body: some View {
        if let image = NSImage(contentsOf: file) {
            ImageZoomPane(file: file, image: image, scale: $scale, controllerBox: box)
                .overlay(alignment: .bottomTrailing) {
                    ZoomControl(
                        percent: Int((scale * 100).rounded()), page: nil,
                        onIn: { box.controller?.zoomIn() }, onOut: { box.controller?.zoomOut() },
                        onFit: { box.controller?.zoomToFit() }, onActual: { box.controller?.zoomActual() },
                        awake: awake)
                        .padding(16)
                }
                .modifier(ZoomWake(awake: $awake))
        } else {
            OtherPane(shown: shown, message: "This image can't be read here. Open it in the app that can.")
        }
    }
}

/// A PDF in PDFKit's view, continuous pages, fit to width by default, with
/// the zoom control and the page shown (v0.20 §3.3).
struct PDFPane: View {
    let file: URL
    @State private var scale: CGFloat = 1
    @State private var page = ""
    @State private var awake = true
    @State private var box = PDFZoomPane.ControllerBox()

    var body: some View {
        PDFZoomPane(file: file, scale: $scale, page: $page, controllerBox: box)
            .overlay(alignment: .bottomTrailing) {
                ZoomControl(
                    percent: Int((scale * 100).rounded()), page: page.isEmpty ? nil : page,
                    onIn: { box.controller?.zoomIn() }, onOut: { box.controller?.zoomOut() },
                    onFit: { box.controller?.zoomToFit() }, onActual: { box.controller?.zoomActual() },
                    awake: awake)
                    .padding(16)
            }
            .modifier(ZoomWake(awake: $awake))
    }
}

/// Plain text and code: monospaced, not wrapped, selectable in the native
/// text view (a drag selects from anywhere). Never auto-opens (spec §5.3),
/// but readable here once picked. Reads the first megabyte only, off the
/// main thread, and says so when the file is longer.
struct TextPane: View {
    let file: URL
    let shown: ArtifactPresentation
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case text(TextFileRead)
        case unreadable
    }

    var body: some View {
        Group {
            switch phase {
            case .loading: LoadingPane()
            case .text(let read): TextBody(read: read, file: file)
            case .unreadable: OtherPane(shown: shown, message: "This file can't be read as text. Open it in the app that can.")
            }
        }
        .task(id: file) {
            let file = file
            let read = await offMain { TextFileRead.read(file, limit: TextFileRead.textLimit) }
            guard !Task.isCancelled else { return }
            phase = read.map(Phase.text) ?? .unreadable
        }
    }
}

/// Text already read, drawn monospaced 12 on scroll views both ways, with a
/// line under it when the file was cut short or a very long line was
/// broken for display (`TextFileRead.hardBreak`).
struct TextBody: View {
    let read: TextFileRead
    /// The file shown, for the agent (v0.12); `nil` draws the text alone.
    var file: URL? = nil
    @Environment(\.viewerAgent) private var agent
    @Environment(\.viewerSlot) private var slot
    @Environment(\.textScale) private var textScale
    @State private var attributed: NSAttributedString?
    @State private var shownText: String?
    @State private var broke = false

    var body: some View {
        VStack(spacing: 0) {
            // A scroll view that scrolls both ways centres content smaller
            // than itself; text starts at the top left like any editor, so
            // the content is at least as big as the pane, aligned there.
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let attributed {
                        SelectableText(text: attributed, wraps: false, onMake: onMake)
                            // Another file is another text view, so the agent is given it.
                            .id(file)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                // At the top when the text arrives, not where the empty
                // pane's middle was (a scroll view both ways keeps the
                // centre as its content grows).
                .defaultScrollAnchor(.topLeading)
            }
            if let note = Self.note(read: read, broke: broke) {
                ViewerFootnote(text: note)
            }
        }
        // Built once, not on every redraw: a megabyte of text is not free.
        // Long lines are broken off the main thread first.
        .task(id: read) {
            let text = read.text
            let shown = await offMain { TextFileRead.hardBreak(text) }
            guard !Task.isCancelled else { return }
            broke = shown.broke
            shownText = shown.text
            attributed = MarkdownAttributed.code(shown.text, scale: textScale)
        }
        // The text the viewer draws follows the text scale (v0.15 §3).
        .onChange(of: textScale) { _, scale in
            if let shownText { attributed = MarkdownAttributed.code(shownText, scale: scale) }
        }
    }

    /// Gives the text view to the agent, in the viewer's panes only.
    private var onMake: ((NSTextView) -> Void)? {
        guard let agent, let file else { return nil }
        return { [slot] in agent.attachNative($0, file: file, slot: slot) }
    }

    /// The line under the text, or `nil` when it is all there as written.
    static func note(read: TextFileRead, broke: Bool) -> String? {
        var parts: [String] = []
        if broke {
            parts.append("Lines longer than \(TextFileRead.displayLineLimit.formatted()) characters are broken to fit.")
        }
        if read.truncated {
            let size = ByteCountFormatter.string(fromByteCount: Int64(read.totalBytes), countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: Int64(TextFileRead.textLimit), countStyle: .file)
            parts.append("Showing the first \(limit) of \(size). Open it externally for the rest.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The small line under a pane that says what it left out.
struct ViewerFootnote: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(text)
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
        }
    }
}

/// A brief "Loading…" while a big file is read off the main thread. At
/// the top left, where the text or table will start, so nothing jumps
/// from the middle of the pane when it arrives.
struct LoadingPane: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A file that is not on disk: says so and why it might be, with the path.
/// No Open button: there is nothing to open.
struct MissingPane: View {
    let shown: ArtifactPresentation

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(Theme.iconFont(36))
                .foregroundStyle(Theme.text3)
            Text("\(shown.title) isn't on disk")
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            Text("The agent's write may have been declined, or the file was moved or deleted after it was made.")
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Text(shown.displayPath)
                .scaledFont(11, design: .monospaced)
                .foregroundStyle(Theme.text3)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the viewer cannot show: why, and a button that opens it in the app
/// macOS would use, named for that app ("Open in Pages").
struct OtherPane: View {
    let shown: ArtifactPresentation
    /// Replaces "Portico can't show <kind> here…" when something more
    /// specific went wrong (an image that would not decode).
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(Theme.iconFont(36))
                .foregroundStyle(Theme.text3)
            Text(shown.title)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            Text(message ?? "\(shown.kindPhrase.prefix(1).uppercased() + shown.kindPhrase.dropFirst()) can't be shown here. Open it in the app that can.")
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button {
                shown.openExternally()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right")
                        .font(Theme.iconFont(10, weight: .semibold))
                    Text(shown.openLabel)
                        .scaledFont(12, weight: .medium)
                }
                .foregroundStyle(Theme.text)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .tip(shown.subtitle)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
