import SwiftUI

// Settings drawn one way (v0.19 §3): every tab the MCP servers way. A
// section's title sits on the panel's left edge; its rows sit in one solid
// `Theme.panel` box, radius 9, a `Theme.borderSubtle` outline, hairlines
// between the rows in `Theme.borderSubtle` too (v0.26, ZF1b: controls keep
// `Theme.border`); the words and the control share a row, help under the words in
// text3. Every control answers the pointer: the hover tint on its hit area,
// the press tint while it is held.

/// The look of a Settings tab: its sections in a scroll view, inset as the
/// MCP servers list is (24 by 18).
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
    }
}

/// A titled panel of rows. Callers pass each row as its own view; the
/// section lays a hairline between them (`Group(subviews:)`, macOS 15), so
/// a row left out by an `if` leaves no stray line. An empty title draws no
/// heading (Appearance, AN3).
struct SettingsSection<Content: View>: View {
    let title: String
    let footnote: String?
    let content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                Text(title)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.text2)
            }
            SettingsPanel {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        row
                    }
                }
            }
            if let footnote {
                Text(footnote)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A grouped panel: the panel colour, radius 9, a `border-subtle` outline (AR1; ZF1b).
struct SettingsPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: SettingsKit.panelRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsKit.panelRadius, style: .continuous)
                    .stroke(SettingsKit.panelOutline, lineWidth: 1))
    }
}

/// The hairline between two rows of a panel.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(SettingsKit.rowLine).frame(height: 1)
    }
}

/// The measures the kit shares.
enum SettingsKit {
    static let panelRadius: CGFloat = 9
    /// v0.26 (PORT-24, ZF1b): a section panel's outline and the lines
    /// between its rows are the quieter `borderSubtle`; controls keep `border`.
    static let panelOutline: Color = Theme.borderSubtle
    static let rowLine: Color = Theme.borderSubtle
    /// A row's inset: 14 across, 10 down, as the MCP servers rows.
    static let rowHorizontal: CGFloat = 14
    static let rowVertical: CGFloat = 10
    /// The corner of a control's tinted hit area.
    static let hitRadius: CGFloat = 5
    /// How a disabled control dims.
    static let disabledOpacity: Double = 0.45
}

extension View {
    /// A panel row's inset, full width, leading.
    func settingsRowInsets() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsKit.rowHorizontal)
            .padding(.vertical, SettingsKit.rowVertical)
    }
}

/// The words and the control on one row; help under the words in text3.
struct SettingsRow<Control: View>: View {
    let label: String
    let help: String?
    let control: Control
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                if let help {
                    Text(help)
                        .scaledFont(11)
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(isEnabled ? 1 : SettingsKit.disabledOpacity)
            Spacer(minLength: 12)
            control
        }
        .settingsRowInsets()
    }
}

/// What a control's hit area is filled with: the press tint while held,
/// the hover tint under the pointer, else nothing; nothing while disabled.
enum SettingsControlState {
    static func background(hovering: Bool, pressed: Bool, enabled: Bool = true) -> Color {
        guard enabled else { return .clear }
        if pressed { return Theme.pressTint }
        if hovering { return Theme.hoverTint }
        return .clear
    }
}

/// What VoiceOver hears for one of the kit's controls: its name, its
/// traits and its value. The views read it, so a test can too.
struct SettingsControlAccessibility: Equatable {
    let label: String
    let traits: AccessibilityTraits
    let value: String?

    static func toggle(_ label: String, isOn: Bool) -> Self {
        Self(label: label, traits: .isToggle, value: isOn ? "On" : "Off")
    }

    /// A radio button or a segment: its own words, selected when chosen.
    static func option(_ label: String, chosen: Bool) -> Self {
        Self(label: label, traits: chosen ? .isSelected : [], value: nil)
    }
}

extension View {
    func settingsAccessibility(_ a: SettingsControlAccessibility) -> some View {
        accessibilityLabel(a.label)
            .accessibilityAddTraits(a.traits)
            .accessibilityValue(a.value ?? "")
    }

    /// A group of options as one container with a name; each option inside
    /// keeps its own name (`.contain`, so the label does not push down).
    @ViewBuilder
    func settingsGroupLabel(_ label: String?) -> some View {
        if let label {
            accessibilityElement(children: .contain).accessibilityLabel(label)
        } else {
            self
        }
    }
}

/// The button style of the kit's switches, checkboxes, radio buttons and
/// segments: the label as drawn, its hit area tinted on hover and press.
struct SettingsControlStyle: ButtonStyle {
    var radius: CGFloat = SettingsKit.hitRadius
    /// Lay the tint over the label rather than under it, for a label with an
    /// opaque fill of its own (the chosen segment).
    var tintOnTop = false

    func makeBody(configuration: Configuration) -> some View {
        Drawn(label: configuration.label, pressed: configuration.isPressed, radius: radius, tintOnTop: tintOnTop)
    }

    private struct Drawn<Label: View>: View {
        let label: Label
        let pressed: Bool
        let radius: CGFloat
        let tintOnTop: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let tint = SettingsControlState.background(hovering: hovering, pressed: pressed, enabled: isEnabled)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            label
                .background(tintOnTop ? .clear : tint, in: shape)
                .overlay { shape.fill(tintOnTop ? tint : .clear).allowsHitTesting(false) }
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .opacity(isEnabled ? 1 : SettingsKit.disabledOpacity)
                .onHover { hovering = $0 }
                .pointerStyle(isEnabled ? .link : nil)
        }
    }
}

/// An on/off switch, drawn here so it can show hover and press: a 26 by 15
/// track, the accent when on, a white knob.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    /// The name is required: VoiceOver reads it, and a switch without one
    /// cannot be written.
    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent : Theme.control)
                    .overlay(Capsule().stroke(isOn ? Color.clear : Theme.borderStrong, lineWidth: 1))
                Circle()
                    .fill(Theme.knob)
                    .shadow(color: Theme.shadowSoft, radius: 0.5, y: 0.5)
                    .padding(1.5)
            }
            .frame(width: 26, height: 15)
            .padding(4)
        }
        .buttonStyle(SettingsControlStyle(radius: 6))
        .settingsAccessibility(.toggle(label, isOn: isOn))
    }
}

/// A checkbox and its words (help under them), the whole of it the hit area.
struct SettingsCheckbox: View {
    let label: String
    let help: String?
    @Binding var isOn: Bool

    init(_ label: String, help: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.help = help
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                SettingsCheckboxBox(isOn: isOn)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .scaledFont(13)
                        .foregroundStyle(Theme.text)
                    if let help {
                        Text(help)
                            .scaledFont(11)
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(SettingsControlStyle())
        .settingsAccessibility(.toggle(label, isOn: isOn))
    }
}

/// The box: the accent with a white tick when on, the control colour in a
/// strong border when off; 14 pt, radius 3.5.
struct SettingsCheckboxBox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(isOn ? Theme.accent : Theme.control)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(isOn ? Color.clear : Theme.borderStrong, lineWidth: 1))
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(Theme.iconFont(9, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                }
            }
            .frame(width: 14, height: 14)
    }
}

/// One choice of several, each a radio button with its words.
struct SettingsRadioGroup<V: Hashable>: View {
    @Binding var selection: V
    let options: [(V, String)]
    let label: String?

    init(selection: Binding<V>, options: [(V, String)], label: String? = nil) {
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    HStack(spacing: 8) {
                        Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                            .font(Theme.iconFont(13))
                            .foregroundStyle(chosen ? Theme.accent : Theme.text3)
                        Text(option.1)
                            .scaledFont(13)
                            .foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .buttonStyle(SettingsControlStyle())
                .settingsAccessibility(.option(option.1, chosen: chosen))
            }
        }
        .settingsGroupLabel(label)
    }
}

/// A segmented choice (AR4): the control colour, radius 7, a border, the
/// chosen segment on the selected fill, radius 5, the hover tint laid over
/// each (over, so it shows on the chosen one too).
struct SettingsSegmented<V: Hashable>: View {
    @Binding var selection: V
    let options: [(V, String)]
    let label: String?

    init(selection: Binding<V>, options: [(V, String)], label: String? = nil) {
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .scaledFont(12, weight: chosen ? .medium : .regular)
                        .foregroundStyle(chosen ? Theme.text : Theme.text2)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                        .background(chosen ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(SettingsControlStyle(radius: 5, tintOnTop: true))
                .settingsAccessibility(.option(option.1, chosen: chosen))
            }
        }
        .padding(2)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .settingsGroupLabel(label)
    }
}

/// A one-line text field as Settings draws it.
struct SettingsTextField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    init(_ label: String, text: Binding<String>, prompt: String) {
        self.label = label
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .scaledFont(12)
    }
}

/// A heading that opens and closes what is under it: a chevron and the
/// title, the hover tint on both; open, the content follows.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    /// Why it can't close now (Gateway's custom connection), else nil.
    /// While set and open, the heading is disabled and says why.
    let lockedOpen: String?
    let content: Content

    init(_ title: String, isOpen: Binding<Bool>, lockedOpen: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        _isOpen = isOpen
        self.lockedOpen = lockedOpen
        self.content = content()
    }

    private var locked: Bool { isOpen && lockedOpen != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(Theme.iconFont(10, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title)
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(Theme.text2)
                }
                .padding(.vertical, 2)
                .padding(.trailing, 6)
            }
            .buttonStyle(SettingsControlStyle())
            .disabled(locked)
            .tip(locked ? lockedOpen ?? "" : "")
            .accessibilityValue(isOpen ? "Open" : "Closed")
            if isOpen {
                content
            }
        }
    }
}

/// AR1–AR3's small buttons: 12-pt label, 4 by 9 padding, radius 6.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case quiet, accent, destructive }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Drawn(kind: kind, configuration: configuration)
    }

    private struct Drawn: View {
        let kind: Kind
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .scaledFont(12, weight: kind == .accent ? .medium : .regular)
                .foregroundStyle(kind == .accent ? Theme.onAccent : kind == .destructive ? Theme.deny : Theme.text)
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .background(kind == .accent ? Theme.accent : Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    if kind != .accent {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(!isEnabled ? .clear : configuration.isPressed ? Theme.pressTint : hovering ? Theme.hoverTint : .clear)
                        .allowsHitTesting(false)
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}
