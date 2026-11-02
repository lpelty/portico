import AppKit
import SwiftUI

/// What the strip under the toolbar says (v0.4, W1): the model · the
/// services, and on the right the update (and "Settings changed — restart
/// the gateway to apply" when the config changed). The chat's state word
/// and its folder are gone: the working line in the conversation says the
/// agent is working, and the Files pane shows the folder. The context is
/// on the session card only (v0.11, item 64). The gateway is one of the
/// services (its own row, from the app), not a segment of its own.
struct StatusStripPresentation: Equatable, Sendable {
    /// The model's name from `context.usage` (A1/S5's Model segment), when known.
    var modelText: String? = nil
    var services: ServicesPresentation
    /// The supervisor's one line about the gateway, for Settings.
    var gatewayText: String
    /// The model as a menu (v0.15, AN1): set only when the gateway has
    /// `models.v1` and the shown session is live; `nil` is plain text.
    var modelMenu: ModelMenuPresentation? = nil

    /// The model segment is the menu, not plain words.
    var hasModelMenu: Bool { modelMenu?.menu == true }

    static let separator = " · "

    /// The whole strip in words, for its tooltip and accessibility.
    var text: String {
        [modelText, services.label].compactMap { $0 }.joined(separator: Self.separator)
    }

    /// How much the strip says at its width (W4): full words, then short
    /// ones, then without the model. It never wraps.
    enum Fit: Int, CaseIterable, Comparable, Sendable {
        case full, compact, minimal

        static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }
    }

    /// The model segment at a fit: the name, the short name, nothing.
    func model(at fit: Fit) -> String? {
        switch fit {
        case .full: modelText
        case .compact: modelText.map(Self.shortModelName)
        case .minimal: nil
        }
    }

    /// The services control's words at a fit: the sentence, else `Services`.
    func servicesLabel(at fit: Fit) -> String {
        fit == .full ? services.label : ServicesPresentation.compactLabel
    }

    // MARK: fitting

    /// The strip's measures, shared by the view and `fit(width:)`.
    enum Measure {
        static let fontSize: CGFloat = 12
        static let sidePadding: CGFloat = 16
        static let spacing: CGFloat = 16
        /// Between an icon and its words.
        static let iconGap: CGFloat = 5
        /// The segments' icons, as drawn.
        static let modelIcon = Symbol(name: "cpu", size: 11)
        static let chevron = Symbol(name: "chevron.down", size: 8, weight: .semibold)
        /// The model menu's own padding either side, inside its hover fill (AN1: 3 × 7).
        static let modelMenuPadding: CGFloat = 7
        static let restartIcon = Symbol(name: "arrow.clockwise", size: 10, weight: .semibold)
        static let updateIcon = Symbol(name: "arrow.down.circle", size: 11)
        static let updateIconCompact = Symbol(name: "arrow.down.circle", size: 13)
        /// The services control around its words: dot and gap, the gap
        /// before the chevron, and its own padding.
        static let servicesChrome: CGFloat = 6 + 5 + 5 + 16
        /// Room left over so a fit is not on the pixel (text drawn a hair
        /// wider than measured, a symbol's optical margins).
        static let slack: CGFloat = 20
    }

    /// An SF Symbol at the size and weight the strip draws it.
    struct Symbol: Equatable, Sendable {
        var name: String
        var size: CGFloat
        var weight: NSFont.Weight = .regular
    }

    /// How the strip's words and icons are measured; the tests give their own.
    struct Metrics {
        /// Words in the strip's font.
        var text: (String) -> CGFloat
        var symbol: (Symbol) -> CGFloat

        /// AppKit's measure of the real fonts and symbols.
        static var system: Metrics { scaled(1) }

        /// The same at a text scale (v0.15 §3): the words grow, the icons
        /// keep their size.
        static func scaled(_ scale: CGFloat) -> Metrics {
            Metrics(text: { textWidth($0, scale: scale) }, symbol: symbolWidth)
        }
    }

    /// The text's width in the strip's font, at a text scale.
    static func textWidth(_ text: String, scale: CGFloat = 1) -> CGFloat {
        let font = Theme.nsFont(Measure.fontSize, scale: scale)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The symbol's width as AppKit draws it; a guess on the generous side
    /// should the symbol be missing.
    static func symbolWidth(_ symbol: Symbol) -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbol.size, weight: symbol.weight)
        guard let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return ceil(symbol.size * 1.5) }
        return ceil(image.size.width)
    }

    /// The width the strip needs at a fit, the right-hand items included
    /// (`restart`: the stale-config button shows, with its words unless
    /// `restartWords` is false; `update`: the version offered).
    func width(
        at fit: Fit, restart: Bool, restartWords: Bool = true, update: String?, metrics: Metrics = .system
    ) -> CGFloat {
        func labelled(_ icon: Symbol, _ text: CGFloat) -> CGFloat {
            metrics.symbol(icon) + Measure.iconGap + text
        }
        var segments: [CGFloat] = []
        if let model = model(at: fit) {
            var segment = labelled(Measure.modelIcon, metrics.text(model))
            if hasModelMenu {
                segment += Measure.iconGap + metrics.symbol(Measure.chevron) + 2 * Measure.modelMenuPadding
            }
            segments.append(segment)
        }
        segments.append(Measure.servicesChrome + metrics.text(servicesLabel(at: fit)) + metrics.symbol(Measure.chevron))
        segments.append(0)  // the spacer
        if restart {
            segments.append(
                restartWords
                    ? labelled(Measure.restartIcon, metrics.text(Self.restartText)) : metrics.symbol(Measure.restartIcon))
        }
        if let update {
            segments.append(
                fit == .full
                    ? labelled(Measure.updateIcon, metrics.text(Self.updateText(update)))
                    : metrics.symbol(Measure.updateIconCompact))
        }
        let gaps = CGFloat(max(segments.count - 1, 0)) * Measure.spacing
        return 2 * Measure.sidePadding + segments.reduce(0, +) + gaps + Measure.slack
    }

    /// What the strip draws at a width: its fit, and whether the
    /// stale-config notice keeps its words (v0.11, item 71).
    struct Layout: Equatable, Sendable {
        var fit: Fit
        var restartWords: Bool
    }

    /// The fullest layout that fits `width`. The other segments shrink
    /// first; the stale-config notice keeps its words through every fit
    /// and becomes a bare icon only when even the minimal strip has no
    /// room for them (v0.11, item 71: it used to fold as soon as the strip
    /// left full, so whenever the viewer was open). A width not measured
    /// yet (the first frame) is the full strip, so it does not flash
    /// minimal first.
    func layout(width: CGFloat?, restart: Bool, update: String?, metrics: Metrics = .system) -> Layout {
        guard let width else { return Layout(fit: .full, restartWords: true) }
        for fit in Fit.allCases
        where self.width(at: fit, restart: restart, update: update, metrics: metrics) <= width {
            return Layout(fit: fit, restartWords: true)
        }
        return Layout(fit: .minimal, restartWords: !restart)
    }

    /// The fullest fit that fits `width`; `minimal` when none does.
    func fit(width: CGFloat?, restart: Bool, update: String?, metrics: Metrics = .system) -> Fit {
        layout(width: width, restart: restart, update: update, metrics: metrics).fit
    }

    // MARK: words

    /// `claude-sonnet-5-5` reads `Claude Sonnet 5.5`; a dated id drops the
    /// date; a name that is not a Claude id is shown as sent.
    static func modelDisplayName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        guard parts.first?.lowercased() == "claude", parts.count > 1 else { return id }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        let words = parts.prefix { Int($0) == nil }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let version = parts.drop { Int($0) == nil }.joined(separator: ".")
        return (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }

    /// The name without its vendor: `Claude Opus 5.5` reads `Opus 5.5`.
    /// A name of one word, or whose second word is a version (`GPT 6`),
    /// stays as it is.
    static func shortModelName(_ name: String) -> String {
        let words = name.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1, let second = words[1].first, !second.isNumber else { return name }
        return words.dropFirst().joined(separator: " ")
    }

    /// The stale-config notice (v0.11, item 63): it names its cause, and
    /// wears the wait colour and a restart arrow where Update available
    /// wears the accent and a download arrow.
    static let restartText = "Settings changed — restart the gateway to apply"

    static func updateText(_ version: String) -> String {
        "Update available (\(version))"
    }

    static func gatewayText(_ status: GatewaySupervisor.Status) -> String {
        switch status {
        case .stopped: "gateway stopped"
        case .starting: "gateway starting"
        case .running(let port): "gateway running :\(port)"
        case .failed(let reason): "gateway failed: \(reason)"
        }
    }
}

extension AppModel {
    /// The strip for the shown chat (or the session the welcome continues)
    /// and the supervisor's view of the gateway.
    func statusStrip(gateway: GatewaySupervisor.Status) -> StatusStripPresentation {
        let menu = shownChat.map { modelMenu(for: $0) }
        return StatusStripPresentation(
            modelText: shownChat.flatMap { stripModelName(for: $0, menu: menu) },
            services: servicesPresentation(gateway: gateway),
            gatewayText: StatusStripPresentation.gatewayText(gateway),
            modelMenu: menu?.menu == true ? menu : nil)
    }

    /// The strip's model name (v0.15): a model just chosen in the menu,
    /// else the one `context.usage` named, else (a menu before any reply)
    /// the current choice, or "Model" while there is no list yet.
    func stripModelName(for chat: Int, menu: ModelMenuPresentation?) -> String? {
        if let chosen = chosenModelName[chat] { return chosen }
        if let name = modelName(for: chat) { return StatusStripPresentation.modelDisplayName(name) }
        guard menu?.menu == true else { return nil }
        return menu?.currentName.map(ModelMenuPresentation.shortChoiceName) ?? "Model"
    }
}

/// The one-line strip under the toolbar. It never wraps: it measures
/// itself and drops words as it narrows (W4).
struct StatusStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: GatewaySupervisor
    /// `nil` until the strip has been laid out once.
    @State private var width: CGFloat?
    @State private var servicesShown = false
    @State private var modelMenuShown = false
    @Environment(\.textScale) private var textScale

    var body: some View {
        let strip = model.statusStrip(gateway: supervisor.status)
        let layout = strip.layout(
            width: width, restart: model.configStale, update: model.offeredUpdate, metrics: .scaled(textScale))
        let fit = layout.fit
        HStack(spacing: StatusStripPresentation.Measure.spacing) {
            if let modelText = strip.model(at: fit) {
                if let menu = strip.modelMenu, menu.menu, let chat = model.shownChat {
                    ModelMenuControl(
                        menu: menu, chat: chat, label: modelText, help: strip.modelText ?? modelText,
                        shown: $modelMenuShown)
                } else {
                    segment(StatusStripPresentation.Measure.modelIcon, modelText, help: strip.modelText)
                }
            }
            ServicesControl(services: strip.services, label: strip.servicesLabel(at: fit), shown: $servicesShown)
            Spacer(minLength: 0)
            if model.configStale {
                restartButton(compact: !layout.restartWords)
            }
            if let version = model.offeredUpdate {
                updateButton(version, compact: fit != .full)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, StatusStripPresentation.Measure.sidePadding)
        .frame(height: Theme.statusStripHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status: \(strip.text)")
    }

    private func segment(_ icon: StatusStripPresentation.Symbol, _ text: String, help: String? = nil) -> some View {
        HStack(spacing: StatusStripPresentation.Measure.iconGap) {
            Image(systemName: icon.name)
                .font(.system(size: icon.size))
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundStyle(Theme.text2)
        .fixedSize()
        .help(help ?? text)
    }

    private func restartButton(compact: Bool) -> some View {
        Button {
            // Asks first while a turn runs (v0.8 decision 3).
            model.request(.restart)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: StatusStripPresentation.Measure.restartIcon.name)
                    .font(.system(size: StatusStripPresentation.Measure.restartIcon.size, weight: .semibold))
                if !compact {
                    Text(model.restarting ? "Restarting…" : StatusStripPresentation.restartText)
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(Theme.wait)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .disabled(model.restarting)
        .help("The settings file changed after the gateway started. Restart the gateway to use them.")
        .accessibilityLabel(StatusStripPresentation.restartText)
    }

    private func updateButton(_ version: String, compact: Bool) -> some View {
        Button {
            Updater.relaunchForUpdate()
        } label: {
            HStack(spacing: 5) {
                let icon = compact ? StatusStripPresentation.Measure.updateIconCompact : StatusStripPresentation.Measure.updateIcon
                Image(systemName: icon.name)
                    .font(.system(size: icon.size))
                if !compact {
                    Text(StatusStripPresentation.updateText(version))
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(model.brand.accent ?? Theme.accent)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help("\(StatusStripPresentation.updateText(version)). Install it: \(model.brand.name) closes, updates, and opens again")
        .accessibilityLabel(StatusStripPresentation.updateText(version))
    }
}

/// What the strip's model menu shows (v0.15, AN1): the engine's models
/// with a check on the current one, dimmed while a reply runs, one dimmed
/// line before any list has come, and plain text (no menu) for a past
/// session or a gateway without `models.v1`.
struct ModelMenuPresentation: Equatable, Sendable {
    var choices: [ModelChoice]
    /// The current choice's `value`; `nil` is the deployment's default.
    var current: String?
    /// A reply is running or a send waits for its answer.
    var busy: Bool
    /// The session is not an ended one open read-only.
    var live: Bool
    /// The gateway's `hello` lists `models.v1`.
    var hasCapability: Bool
    /// The socket is up: a choice made now would go nowhere.
    var connected: Bool = true

    static let busyHelp = "Change the model after this reply"
    static let disconnectedHelp = "Not connected"
    static let emptyText = "Models appear once the session starts"
    static let footer = "Applies to this session and new ones."

    /// The model is a menu, not plain words.
    var menu: Bool { hasCapability && live }
    /// The menu opens; dimmed while a reply runs.
    var enabled: Bool { menu && !busy && connected }
    /// The dimmed menu's tooltip: why it is dimmed.
    var help: String? {
        guard menu else { return nil }
        if !connected { return Self.disconnectedHelp }
        return busy ? Self.busyHelp : nil
    }
    /// The menu's one line when there is no list yet.
    var emptyLine: String? { choices.isEmpty ? Self.emptyText : nil }

    func checked(_ value: String) -> Bool {
        (current ?? Models.defaultValue) == value
    }

    /// The current choice's name, for the strip before a reply names the model.
    var currentName: String? {
        choices.first { checked($0.value) }?.displayName
    }

    /// A choice's name for the strip: without a trailing parenthetical
    /// ("Default (recommended)" reads "Default").
    static func shortChoiceName(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let trimmed = name[..<open].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }
}

/// The strip's model as a menu (v0.15, AN1): the chip and name, a chevron
/// in the third text colour, the hover fill; a click opens the list.
struct ModelMenuControl: View {
    let menu: ModelMenuPresentation
    let chat: Int
    let label: String
    /// The tooltip when the menu is not dimmed: the full model name.
    let help: String
    @Binding var shown: Bool
    @EnvironmentObject private var model: AppModel

    private typealias Measure = StatusStripPresentation.Measure

    var body: some View {
        // The tooltip sits on a wrapper: a disabled button's own may not show,
        // and the dimmed menu's tooltip is the reason it is dimmed.
        HStack(spacing: 0) {
            Button {
                shown.toggle()
            } label: {
                HStack(spacing: Measure.iconGap) {
                    Image(systemName: Measure.modelIcon.name)
                        .font(.system(size: Measure.modelIcon.size))
                    Text(label)
                        .font(.system(size: Measure.fontSize))
                    Image(systemName: shown ? "chevron.up" : Measure.chevron.name)
                        .font(.system(size: Measure.chevron.size, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .foregroundStyle(Theme.text2)
                .fixedSize()
                .padding(.horizontal, Measure.modelMenuPadding)
                .padding(.vertical, 3)
                .background(shown ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
            .disabled(!menu.enabled)
            .opacity(menu.enabled ? 1 : 0.5)
        }
        .help(menu.help ?? help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Model: \(label)")
        .accessibilityHint(menu.help ?? "Choose the model")
        .onChange(of: menu.enabled) { _, enabled in
            if !enabled { shown = false }
        }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ModelMenu(chat: chat, closeMenu: { shown = false })
                .lineLimit(nil)
                .environmentObject(model)
        }
    }
}

/// The model menu (AN1): each choice's name over its description, a check
/// in the accent on the current one, and the footer saying where it
/// applies. Reads the model itself so a new `models` frame shows while open.
struct ModelMenu: View {
    let chat: Int
    var closeMenu: () -> Void = {}
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let menu = model.modelMenu(for: chat)
        VStack(alignment: .leading, spacing: 1) {
            if let empty = menu.emptyLine {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            } else {
                ForEach(menu.choices) { choice in
                    ModelChoiceRow(
                        choice: choice, checked: menu.checked(choice.value),
                        accent: model.brand.accent ?? Theme.accent
                    ) {
                        model.setModel(choice.value, chat: chat)
                        closeMenu()
                    }
                    .disabled(!menu.enabled)
                }
                Text(ModelMenuPresentation.footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Under the names: past the row's padding, check and gap.
                    .padding(EdgeInsets(top: 8, leading: 10 + 14 + 9, bottom: 4, trailing: 10))
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .padding(6)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One choice in the model menu: the check's place, the name (medium when
/// current), the description in the third text colour.
struct ModelChoiceRow: View {
    let choice: ModelChoice
    let checked: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.displayName)
                        .font(.system(size: 13, weight: checked ? .medium : .regular))
                        .foregroundStyle(Theme.text)
                    if !choice.description.isEmpty {
                        Text(choice.description)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                hovering && isEnabled ? Theme.selected : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// The strip's services control (W3): a dot and the services sentence
/// (or "Services") with a chevron; a click opens the menu.
struct ServicesControl: View {
    let services: ServicesPresentation
    let label: String
    @Binding var shown: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: GatewaySupervisor

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(ServiceColors.tone(services.tone))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(services.tone == .down ? Theme.wait : Theme.text2)
                Image(systemName: shown ? "chevron.up" : StatusStripPresentation.Measure.chevron.name)
                    .font(.system(size: StatusStripPresentation.Measure.chevron.size, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(shown ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(services.label)
        .accessibilityLabel("Services: \(services.label)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            // A popover is its own window: hand it what the menu reads.
            // The strip is one line (`.lineLimit(1)` above), and that
            // reaches into the popover: undo it so details wrap.
            // A question the menu asks closes it: the sheet is the window's.
            ServicesMenu(closeMenu: { shown = false })
                .lineLimit(nil)
                .environmentObject(model)
                .environmentObject(supervisor)
        }
    }
}

/// The services colours: green up, amber for the strip's "down", grey
/// while checking; a down row's own dot is red.
enum ServiceColors {
    static func tone(_ tone: ServicesPresentation.Tone) -> Color {
        switch tone {
        case .up: Theme.working
        case .down: Theme.wait
        case .checking: Theme.idle
        }
    }

    static func row(_ state: ServiceState) -> Color {
        switch state {
        case .up: Theme.working
        case .down: Theme.deny
        case .checking: Theme.idle
        }
    }
}

/// The services menu (W3; v0.11, item 60, AG3): one line per service,
/// its dot carrying the state, and a second line only when it says
/// something (the gateway's port, a check's detail, an error in red). One
/// Restart all at the foot. The Gateway row shows Stop and Restart on hover (v0.12);
/// a row's own Restart, and the gateway's Stop or Start, are also on its context menu. Reads the
/// model itself so it stays current while open.
struct ServicesMenu: View {
    /// Closes the popover, so a confirmation sheet is not hidden behind it.
    var closeMenu: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: GatewaySupervisor

    var body: some View {
        let services = model.servicesPresentation(gateway: supervisor.status)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(services.rows) { row in
                ServiceRowView(row: row, closeMenu: closeMenu)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.top, 4)
            RestartAllRow(closeMenu: closeMenu)
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8))
        }
        .padding(8)
        .frame(width: 420)
        // A popover takes its content's ideal size; without this the
        // wrapped lines above are measured as one line and cut short.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One service in the menu: dot, name, and the second line when there is
/// one (`ServiceRow.menuDetail`), red when it is an error. A restart the
/// row asked for spins at its end; when it fails, the gateway's reason
/// shows under the row in red until the next try (v0.8). The context menu
/// has the row's Restart (a deployment service with a restart command) or
/// the gateway's Stop or Start and Restart, as Settings › Gateway (v0.8
/// decision 3).
struct ServiceRowView: View {
    let row: ServiceRow
    var closeMenu: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(ServiceColors.row(row.state))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                // The whole line, wrapped: a down service's reason is the
                // part worth reading, so it is never cut short (v0.5).
                if let detail = row.menuDetail {
                    line(detail, error: row.menuDetailIsError)
                }
                if let reason = restartError {
                    line(reason, error: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if restarting {
                ProgressView().controlSize(.small)
                    .help("Restarting \(row.name)…")
            } else if hovering {
                // v0.12, item 1: the Gateway row's Stop and Restart, visible on hover,
                // drawn as the app's other small row actions (Copy under a reply).
                HStack(spacing: 2) {
                    ForEach(ServicesPresentation.hoverControls(row), id: \.title) { control in
                        RowActionButton(title: control.title, systemImage: control.systemImage, help: Self.help(control)) {
                            press(control)
                        }
                        .disabled(!ServicesPresentation.gatewayControlEnabled(control, gateway: row, restarting: model.restarting))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The whole row, padding included, is the hover target (v0.14 test
        // fix): before the padding and the shape, only the drawn dot and
        // words counted, a thin strip the pointer had to find.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
    }

    private func line(_ text: String, error: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(error ? Theme.deny : Theme.text2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var restartError: String? {
        row.isGateway ? nil : model.restartError(service: row.id)
    }

    private var restarting: Bool {
        row.isGateway ? model.restarting : model.isRestarting(service: row.id)
    }

    @ViewBuilder
    private var actions: some View {
        if row.isGateway {
            ForEach(ServicesPresentation.gatewayControls(row), id: \.title) { control in
                Button("\(control.title) gateway") { press(control) }
                    .disabled(!ServicesPresentation.gatewayControlEnabled(control, gateway: row, restarting: model.restarting))
            }
        } else if row.canRestart {
            Button("Restart \(row.name)") { model.restartService(row.id) }
                .disabled(!model.canRestart(service: row.id))
        }
    }

    private func press(_ control: GatewayControl) {
        switch control {
        case .start: model.startGateway()
        case .stop: if model.request(.stop) { closeMenu() }
        case .restart: if model.request(.restart) { closeMenu() }
        }
    }

    static func help(_ control: GatewayControl) -> String {
        switch control {
        case .start: "Start the gateway"
        case .stop: "Stop the gateway: running turns are interrupted"
        case .restart: "Stop the gateway and start it again, reading the config afresh"
        }
    }
}

/// The menu's one restart control, full width at its foot (v0.11, item
/// 60): the deployment's restart command for all its services when it has
/// one (asks first, sends `services.restart_all`, spins until a fresh
/// `services.status`), else a restart of the gateway (asks while a turn
/// runs). The gateway's reason shows under it in red when it fails.
struct RestartAllRow: View {
    var closeMenu: () -> Void = {}
    @EnvironmentObject private var model: AppModel

    private var action: GatewayAction {
        ServicesPresentation.restartAllAction(offersRestartAll: model.offersRestartAll)
    }

    private var busy: Bool {
        action == .restartAll ? model.restartingAll != nil : model.restarting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if model.request(action) { closeMenu() }
            } label: {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.text2)
                    }
                    Text(busy ? "Restarting…" : ServicesPresentation.restartAllTitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .disabled(busy || (action == .restartAll && model.connection != .connected))
            .help(action == .restartAll
                ? "Run the deployment's restart command for all its services"
                : ServiceRowView.help(.restart))
            if let reason = model.restartAllError {
                // As a down row's reason: the whole of it, wrapped, red.
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deny)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
