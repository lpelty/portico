import AppKit
import SwiftUI

/// What the strip under the toolbar says (v0.4, W1): the model · the
/// context · the services, and on the right the update (and "restart to
/// apply" when the config changed). The chat's state word and its folder
/// are gone: the working line in the conversation says the agent is
/// working, and the Files pane shows the folder. The gateway is one of the
/// services (its own row, from the app), not a segment of its own.
struct StatusStripPresentation: Equatable, Sendable {
    /// The model's name from `context.usage` (A1/S5's Model segment), when known.
    var modelText: String? = nil
    /// The context window's fullness, 0–100, when the gateway reports it.
    var contextPercent: Double? = nil
    var services: ServicesPresentation
    /// The supervisor's one line about the gateway, for Settings.
    var gatewayText: String

    static let separator = " · "

    /// `62% context`.
    var contextText: String? { contextPercent.map(Self.contextText) }

    /// The whole strip in words, for its tooltip and accessibility.
    var text: String {
        [modelText, contextText, services.label].compactMap { $0 }.joined(separator: Self.separator)
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

    /// The context segment at a fit: `2% context`, else `2%`.
    func context(at fit: Fit) -> String? {
        guard let contextPercent else { return nil }
        return fit == .full ? Self.contextText(contextPercent) : Self.percentText(contextPercent)
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
        static let contextIcon = Symbol(name: "gauge.with.dots.needle.50percent", size: 11)
        static let chevron = Symbol(name: "chevron.down", size: 8, weight: .semibold)
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
        /// Words with `.monospacedDigit()`, as the context is drawn.
        var digits: (String) -> CGFloat
        var symbol: (Symbol) -> CGFloat

        /// AppKit's measure of the real fonts and symbols.
        static var system: Metrics {
            Metrics(text: textWidth, digits: digitWidth, symbol: symbolWidth)
        }
    }

    /// The text's width in the strip's font.
    static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Measure.fontSize)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The text's width in the strip's font with monospaced digits.
    static func digitWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Measure.fontSize, weight: .regular)
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
    /// (`restart`: the stale-config button shows; `update`: the version
    /// offered).
    func width(at fit: Fit, restart: Bool, update: String?, metrics: Metrics = .system) -> CGFloat {
        func labelled(_ icon: Symbol, _ text: CGFloat) -> CGFloat {
            metrics.symbol(icon) + Measure.iconGap + text
        }
        var segments: [CGFloat] = []
        if let model = model(at: fit) { segments.append(labelled(Measure.modelIcon, metrics.text(model))) }
        if let context = context(at: fit) { segments.append(labelled(Measure.contextIcon, metrics.digits(context))) }
        segments.append(Measure.servicesChrome + metrics.text(servicesLabel(at: fit)) + metrics.symbol(Measure.chevron))
        segments.append(0)  // the spacer
        if restart {
            segments.append(
                fit == .full
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

    /// The fullest fit that fits `width`; `minimal` when none does. A
    /// width not measured yet (the first frame) is the full strip, so it
    /// does not flash minimal first.
    func fit(width: CGFloat?, restart: Bool, update: String?, metrics: Metrics = .system) -> Fit {
        guard let width else { return .full }
        return Fit.allCases.first { self.width(at: $0, restart: restart, update: update, metrics: metrics) <= width } ?? .minimal
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

    static let restartText = "Restart the gateway to apply"

    static func updateText(_ version: String) -> String {
        "Update available (\(version))"
    }

    /// `62% context`, rounded to a whole percent.
    static func contextText(_ percent: Double) -> String {
        "\(percentText(percent)) context"
    }

    /// `62%`.
    static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
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
    /// The strip for the selected chat and the supervisor's view of the gateway.
    func statusStrip(gateway: GatewaySupervisor.Status) -> StatusStripPresentation {
        StatusStripPresentation(
            modelText: selected.flatMap { modelName(for: $0) }.map(StatusStripPresentation.modelDisplayName),
            contextPercent: selected.flatMap { contextPercent(for: $0) },
            services: servicesPresentation(gateway: gateway),
            gatewayText: StatusStripPresentation.gatewayText(gateway))
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

    var body: some View {
        let strip = model.statusStrip(gateway: supervisor.status)
        let fit = strip.fit(width: width, restart: model.configStale, update: model.offeredUpdate)
        HStack(spacing: StatusStripPresentation.Measure.spacing) {
            if let modelText = strip.model(at: fit) {
                segment(StatusStripPresentation.Measure.modelIcon, modelText, help: strip.modelText)
            }
            if let context = strip.context(at: fit) {
                segment(StatusStripPresentation.Measure.contextIcon, context, monospaced: true)
            }
            ServicesControl(services: strip.services, label: strip.servicesLabel(at: fit), shown: $servicesShown)
            Spacer(minLength: 0)
            if model.configStale {
                restartButton(compact: fit != .full)
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

    private func segment(
        _ icon: StatusStripPresentation.Symbol, _ text: String, monospaced: Bool = false, help: String? = nil
    ) -> some View {
        HStack(spacing: StatusStripPresentation.Measure.iconGap) {
            Image(systemName: icon.name)
                .font(.system(size: icon.size))
            Text(text)
                .font(monospaced ? .system(size: 12).monospacedDigit() : .system(size: 12))
        }
        .foregroundStyle(Theme.text2)
        .fixedSize()
        .help(help ?? text)
    }

    private func restartButton(compact: Bool) -> some View {
        Button {
            Task { await model.restartGateway() }
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
        .help("The config file changed after the gateway started. Restart it to apply the change.")
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
            ServicesMenu()
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

/// The services menu (W3): SERVICES, a row per service (dot, name, one
/// line of detail, Restart when the deployment has a restart command),
/// and a footer line. Reads the model itself so it stays current while open.
struct ServicesMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: GatewaySupervisor

    var body: some View {
        let services = model.servicesPresentation(gateway: supervisor.status)
        VStack(alignment: .leading, spacing: 2) {
            SidebarSectionLabel("Services")
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(services.rows) { row in
                ServiceRowView(row: row)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.vertical, 6)
            Text(ServicesPresentation.footer)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(10)
        .frame(width: 340)
    }
}

/// One service in the menu. A down row is tinted; Restart sends
/// `service.restart` and spins until the next status.
struct ServiceRowView: View {
    let row: ServiceRow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(ServiceColors.row(row.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                // The whole detail, wrapped: a down service's reason is
                // the part worth reading, so it is never cut short (v0.5).
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.canRestart && !row.isGateway {
                if model.isRestarting(service: row.id) {
                    ProgressView().controlSize(.small)
                        .help("Restarting \(row.name)…")
                } else {
                    Button("Restart") { model.restartService(row.id) }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .controlSize(.small)
                        .disabled(model.connection != .connected)
                        .help("Run the deployment's restart command for \(row.name)")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(row.state == .down ? Theme.waitSoft : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
