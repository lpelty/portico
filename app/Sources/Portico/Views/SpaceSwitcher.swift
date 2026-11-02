import SwiftUI

// The spaces switcher (v0.12, spec 4.2, rows AI1 and AI2) and the pure
// parts behind it: the toolbar's order, the "Updated" wording, the menu's
// filter and selection. A space is a file the agent keeps current; the
// switcher moves between Work (chat, files, the viewer) and the spaces.

/// What the toolbar holds, in order (spec 5). The chat's title is not here:
/// the session card names the session.
enum ToolbarLayout {
    enum Item: String, Equatable {
        case sidebarToggle, brand, switcher, thread, spacer, viewerToggle
    }

    /// In a thread, the way back to Main (v0.16 §2.3; §9.1–9.2: no chip
    /// beside it, no key glyph on it; the tooltip spells the key).
    static let backToMainLabel = "← Main"
    static let backToMainHelp = "Back to Main (Control-0)"

    /// The gap between the brand and the switcher: 26 pt, as drawn in Pen (v0.13 decision 6; was 6).
    static let brandToSwitcherGap: CGFloat = 26

    /// v0.14: the switcher is never hidden. With no spaces its menu still offers Work and New space…
    /// (dimmed on a gateway without `spaces.v1`).
    static let showsSwitcher = true

    /// The pill's title stops here (about 220 pt pill) and truncates.
    static let switcherTitleMaxWidth: CGFloat = 160

    /// Room after `item` before the next one: the brand sits 26 pt from the switcher.
    static func gap(after item: Item, next: Item?) -> CGFloat {
        switch (item, next) {
        case (.brand, .switcher?): return brandToSwitcherGap
        case (.spacer, _), (_, nil): return 0
        default: return 12
        }
    }

    /// `inThread`: the window shows a thread, so "← Main" follows the
    /// switcher (v0.16, AM3; the thread's chip was dropped in §9.1).
    static func items(showSwitcher: Bool, showViewerToggle: Bool, inThread: Bool = false) -> [Item] {
        var items: [Item] = [.sidebarToggle, .brand]
        if showSwitcher { items.append(.switcher) }
        if inThread { items.append(.thread) }
        items.append(.spacer)
        if showViewerToggle { items.append(.viewerToggle) }
        return items
    }
}

enum SpacesPresentation {
    /// ⌘0 is Work; ⌘1–⌘9 the first nine spaces.
    static let shortcutDigits = Array(0...9)

    /// The SPACES section's note when there are none yet.
    static let noSpacesText = "No spaces yet"

    /// New space…'s tooltip when the gateway predates spaces.
    static let tooOldHelp = "This Portico gateway is too old for spaces."

    /// New space… works only against a gateway that advertises `spaces.v1`.
    static func canCreateSpace(capabilities: [String]?) -> Bool {
        capabilities?.contains(SpacesList.capability) == true
    }

    /// The "No spaces yet" note shows under SPACES when there are no spaces and no filter is typed.
    static func showsEmptyNote(spaces: [SpaceInfo], query: String) -> Bool {
        spaces.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A space's own front-matter keys, kept out of the Properties block.
    static let hiddenFrontMatterKeys: Set<String> = ["title", "icon", "order"]

    /// The notification's body: "Updated — 7:02 AM".
    static func notificationBody(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return "Updated — " + f.string(from: date)
    }

    /// The menu's list scrolls past this height (about nine rows); Work, New space… and the hint stay put.
    static let listMaxHeight: CGFloat = 9 * 50

    static func removeConfirmation(title: String) -> String {
        "Remove \(title)? The agent stops keeping it up to date. The file moves to the Trash."
    }

    /// The renamed title to send, or `nil` when there is nothing to send (blank, or no change).
    static func renamedTitle(_ typed: String, current: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == current ? nil : trimmed
    }

    /// "Updated 7:02 AM" today, "Updated yesterday, 5:40 PM", "Updated Mon
    /// 8:04 AM" within the last week, else "Updated Oct 24" (with the year
    /// when it is not this one).
    static func updatedText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "Updated" }
        func format(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Updated " + format("jmm")
        case 1: return "Updated yesterday, " + format("jmm")
        case 2..<7: return "Updated " + format("EEE") + " " + format("jmm")
        default:
            return "Updated " + (calendar.isDate(date, equalTo: now, toGranularity: .year) ? format("MMMd") : format("MMMdy"))
        }
    }
}

/// Which row of the menu is selected, and what the typed filter leaves.
struct SpaceMenuState: Equatable {
    enum Entry: Hashable {
        case work
        case space(String)
        case newSpace

        /// Pick it: Work and the spaces open (or close) the viewer's space; New space… asks the composer.
        @MainActor func choose(on model: AppModel) {
            switch self {
            case .work: model.setOpenSpace(nil)
            case .space(let id): model.setOpenSpace(id)
            case .newSpace: model.beginNewSpace()
            }
        }
    }

    var query = ""
    var selection: Entry? = .work

    /// The rows the filter leaves, in menu order. Empty filter: all.
    func visible(_ spaces: [SpaceInfo]) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ label: String) -> Bool { needle.isEmpty || label.lowercased().contains(needle) }
        var entries: [Entry] = []
        if matches("Work") { entries.append(.work) }
        entries += spaces.filter { matches($0.title) }.map { .space($0.id) }
        if matches("New space") { entries.append(.newSpace) }
        return entries
    }

    /// A new filter keeps the selection when it still shows, else takes the first match.
    mutating func setQuery(_ text: String, spaces: [SpaceInfo]) {
        query = text
        let entries = visible(spaces)
        if let selection, entries.contains(selection) { return }
        selection = entries.first
    }

    /// Esc clears a typed filter first; with none, it closes. True means close.
    mutating func escape(spaces: [SpaceInfo]) -> Bool {
        guard !query.isEmpty else { return true }
        setQuery("", spaces: spaces)
        return false
    }

    /// Up and down stop at the ends.
    mutating func move(_ delta: Int, spaces: [SpaceInfo]) {
        let entries = visible(spaces)
        guard !entries.isEmpty else { selection = nil; return }
        guard let selection, let index = entries.firstIndex(of: selection) else { self.selection = entries.first; return }
        self.selection = entries[min(max(index + delta, 0), entries.count - 1)]
    }
}

/// The pill after the brand: the open space's icon and name, or Work. A dot
/// when any space has something new. Its menu is a popover.
struct SpaceSwitcher: View {
    @EnvironmentObject private var model: AppModel
    @State private var open = false
    @State private var pendingRemove: SpaceInfo?

    private var current: SpaceInfo? { model.openSpace.flatMap { id in model.spaces.first { $0.id == id } } }
    private var anyNew: Bool { model.spaces.contains { model.hasNew($0.id) } }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: current?.icon ?? "briefcase")
                    .font(Theme.iconFont(12))
                    .foregroundStyle(Theme.text2)
                Text(current?.title ?? "Work")
                    .scaledFont(12.5, weight: .medium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: ToolbarLayout.switcherTitleMaxWidth, alignment: .leading)
                if anyNew { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                Image(systemName: "chevron.down")
                    .font(Theme.iconFont(8, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help("Switch between Work and your spaces")
        .accessibilityLabel("Space: \(current?.title ?? "Work")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SpaceMenu(dismiss: { open = false }, askToRemove: { space in
                open = false
                pendingRemove = space
            })
            .environmentObject(model)
            .popoverSurface()
        }
        .confirmationDialog(
            pendingRemove.map { SpacesPresentation.removeConfirmation(title: $0.title) } ?? "",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let space = pendingRemove { model.removeSpace(space.id) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
    }
}

/// The menu (row AI1): Work, SPACES, each space, New space…, and the hint.
private struct SpaceMenu: View {
    @EnvironmentObject private var model: AppModel
    let dismiss: () -> Void
    let askToRemove: (SpaceInfo) -> Void

    @State private var state = SpaceMenuState()
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var focused: Bool
    @FocusState private var renameFocused: Bool

    private var entries: [SpaceMenuState.Entry] { state.visible(model.spaces) }
    private var canCreate: Bool { SpacesPresentation.canCreateSpace(capabilities: model.hello?.capabilities) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.query.isEmpty {
                Text(state.query)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if entries.isEmpty {
                Text("No match").scaledFont(12).foregroundStyle(Theme.text2).padding(10)
            }
            if entries.contains(.work) {
                row(.work, icon: "briefcase", title: "Work", detail: "Chat, files and the viewer", shortcut: "⌘0", current: model.openSpace == nil)
            }
            let spaceEntries = model.spaces.enumerated().filter { entries.contains(.space($0.element.id)) }
            let emptyNote = SpacesPresentation.showsEmptyNote(spaces: model.spaces, query: state.query)
            if !spaceEntries.isEmpty || emptyNote {
                Text("SPACES")
                    .scaledFont(10.5, weight: .medium)
                    .tracking(0.5)
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                if emptyNote {
                    Text(SpacesPresentation.noSpacesText)
                        .scaledFont(12)
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 10).padding(.bottom, 6)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(spaceEntries, id: \.element.id) { index, space in
                                spaceRow(space, number: index + 1).id(space.id)
                            }
                        }
                    }
                    .frame(maxHeight: SpacesPresentation.listMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: state.selection) { _, selection in
                        if case .space(let id)? = selection { proxy.scrollTo(id) }
                    }
                }
            }
            if entries.contains(.newSpace) {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
                row(.newSpace, icon: "plus", title: "New space…", detail: "Say what you want kept up to date; \(model.hello?.brand.agentName ?? "the agent") sets it up", shortcut: nil, current: false, enabled: canCreate)
            }
            Text("↑↓ move · Return opens · ⌘0–9 from anywhere")
                .scaledFont(10.5)
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
        }
        .padding(6)
        .frame(width: 380)
        .background(Theme.panel)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard renaming == nil else { return .ignored }
        switch press.key {
        case .upArrow: state.move(-1, spaces: model.spaces); return .handled
        case .downArrow: state.move(1, spaces: model.spaces); return .handled
        case .return:
            if let selection = state.selection { pick(selection) }
            return .handled
        case .escape:
            if state.escape(spaces: model.spaces) { dismiss() }
            return .handled
        case .delete:
            if !state.query.isEmpty { state.setQuery(String(state.query.dropLast()), spaces: model.spaces) }
            return .handled
        default:
            let typed = press.characters
            guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                typed.count == 1, let scalar = typed.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar)
            else { return .ignored }
            state.setQuery(state.query + typed, spaces: model.spaces)
            return .handled
        }
    }

    private func pick(_ entry: SpaceMenuState.Entry) {
        if entry == .newSpace, !canCreate { return }
        entry.choose(on: model)
        dismiss()
    }

    @ViewBuilder
    private func row(_ entry: SpaceMenuState.Entry, icon: String, title: String, detail: String, shortcut: String?, current: Bool, enabled: Bool = true) -> some View {
        Button { pick(entry) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(Theme.iconFont(13)).foregroundStyle(Theme.text2).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaledFont(13, weight: .medium).foregroundStyle(Theme.text)
                    Text(detail).scaledFont(11.5).foregroundStyle(Theme.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if current { Image(systemName: "checkmark").font(Theme.iconFont(11, weight: .semibold)).foregroundStyle(Theme.text2) }
                if let shortcut { Text(shortcut).scaledFont(11).foregroundStyle(Theme.text2) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(state.selection == entry ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(enabled ? "" : SpacesPresentation.tooOldHelp)
        .onHover { if $0 { state.selection = entry } }
    }

    @ViewBuilder
    private func spaceRow(_ space: SpaceInfo, number: Int) -> some View {
        let entry = SpaceMenuState.Entry.space(space.id)
        let isNew = model.hasNew(space.id)
        if renaming == space.id {
            HStack(spacing: 10) {
                Image(systemName: space.icon).font(Theme.iconFont(13)).foregroundStyle(Theme.text2).frame(width: 18)
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onAppear { renameFocused = true }
                    .onSubmit { commitRename(space) }
                    .onKeyPress(.escape) { cancelRename(); return .handled }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        } else {
            Button { pick(entry) } label: {
                HStack(spacing: 10) {
                    Image(systemName: space.icon).font(Theme.iconFont(13)).foregroundStyle(Theme.text2).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(space.title).scaledFont(13, weight: .medium).foregroundStyle(Theme.text).lineLimit(1)
                        Text(SpacesPresentation.updatedText(space.updatedDate))
                            .scaledFont(11.5)
                            .foregroundStyle(isNew ? Theme.accent : Theme.text2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if isNew { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                    if number <= 9 { Text("⌘\(number)").scaledFont(11).foregroundStyle(Theme.text2) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(state.selection == entry ? Theme.selected : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { if $0 { state.selection = entry } }
            .contextMenu {
                Button("Rename…") {
                    renameText = space.title
                    renaming = space.id
                }
                Button("Remove…") { askToRemove(space) }
            }
        }
    }

    private func commitRename(_ space: SpaceInfo) {
        if let title = SpacesPresentation.renamedTitle(renameText, current: space.title) { model.renameSpace(space.id, to: title) }
        cancelRename()
    }

    private func cancelRename() {
        renaming = nil
        focused = true
    }
}
