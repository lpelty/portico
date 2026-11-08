import SwiftUI

/// Settings › Labs (v0.25 §2, ZE1): features being tried out on this Mac.
/// One block per item: its title and tag, a note on where it was turned on,
/// then a box with its controls (Read aloud) or what the plug-in said (any
/// other key). Shown only while there is an item (`SettingsTab.visible`).
struct LabsSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    /// The tab's header line (ruling 1, ZE1's text).
    static let header =
        "Features being tried out on this Mac. They may change or go away. Everything in the other tabs is what everyone gets."

    var body: some View {
        SettingsPage {
            Text(Self.header)
                .scaledFont(12)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.labItems) { item in
                LabItemBlock(item: item, elevenLabs: item.key == LabItem.readAloudKey ? model.elevenLabsItem : nil)
            }
        }
    }
}

/// What a Labs item's box holds (v0.26, review L12): Read aloud's controls only
/// when Read aloud is available here; any other key, what the plug-in said.
enum LabItemContent: Equatable {
    case readAloudControls, unavailable, info

    static let unavailableLine = "Read aloud isn't available here."

    static func `for`(_ item: LabItem, readAloudAvailable: Bool) -> LabItemContent {
        guard item.key == LabItem.readAloudKey else { return .info }
        return readAloudAvailable ? .readAloudControls : .unavailable
    }
}

/// One Labs item: the header row, the note, the box.
private struct LabItemBlock: View {
    @EnvironmentObject private var settings: Settings
    let item: LabItem
    /// v0.26: the ElevenLabs voices item, folded into Read aloud's note.
    var elevenLabs: LabItem? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.title)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                LabTagPill(tag: item.tag)
            }
            Text(LabPresentation.note(item, elevenLabs: elevenLabs))
                .scaledFont(11.5)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            switch LabItemContent.for(item, readAloudAvailable: settings.readAloudAvailable) {
            case .readAloudControls:
                ReadAloudControls()
            case .unavailable:
                SettingsPanel {
                    Text(LabItemContent.unavailableLine)
                        .scaledFont(13)
                        .foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsRowInsets()
                }
            case .info:
                SettingsPanel {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.detail)
                                .scaledFont(13)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Set in the plug-in's own config.")
                                .scaledFont(11)
                                .foregroundStyle(Theme.text3)
                        }
                        Spacer(minLength: 12)
                        Text("On")
                            .scaledFont(13)
                            .foregroundStyle(Theme.text2)
                    }
                    .settingsRowInsets()
                }
            }
        }
    }
}

/// Preview (accent on accentSoft) or Local (text2 on control), solid; an
/// unknown tag (review L11) draws no pill.
struct LabTagPill: View {
    let tag: LabItem.Tag

    static func label(for tag: LabItem.Tag) -> String? {
        switch tag {
        case .preview: "Preview"
        case .local: "Local"
        default: nil
        }
    }

    var body: some View {
        if let label = Self.label(for: tag) {
            pill(label)
        }
    }

    private func pill(_ label: String) -> some View {
        Text(label)
            .scaledFont(11, weight: .semibold)
            .foregroundStyle(tag == .preview ? Theme.accent : Theme.text2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                tag == .preview ? Theme.accentSoft : Theme.control,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                if tag == .local {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.border, lineWidth: 1)
                }
            }
    }
}

/// Read aloud's switch, voice, speed and sample (moved unchanged from
/// Settings › Voice's Listen section, v0.25 §2.2; the switch gains ZE1's
/// subtitle, ruling 3). Everything here runs on this Mac.
struct ReadAloudControls: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var reader: ReadAloud
    @State private var voices: [VoiceOption] = []
    @State private var personal: PersonalVoiceAccess = .unsupported

    /// The switch's subtitle (ruling 3).
    static let switchHelp = "A Play button on each reply; replies are read as they arrive while it's on."

    /// Read aloud's footnote with This Mac's voices.
    static let thisMacFootnote =
        "Read aloud speaks a reply's spoken summary when the agent marks one, otherwise its text. Code and tables are never read; you hear \"See the code below.\" Esc stops reading."
    /// v0.26 (PORT-23, ruling 8): the footnote while the source is ElevenLabs.
    static let elevenLabsFootnote =
        "Replies are sent to ElevenLabs to be spoken, and count against your ElevenLabs plan. If ElevenLabs can't speak a reply, it's read with this Mac's voice and a note says why."

    /// The rows drawn, in order (ZG1), for the tests and the body alike.
    enum Row: Equatable { case readAloud, voiceSource, apiKey, elevenLabsVoice, model, macVoice, speed, sample }

    static func rows(elevenLabsAvailable: Bool, source: VoiceSource) -> [Row] {
        var rows: [Row] = [.readAloud]
        if elevenLabsAvailable { rows.append(.voiceSource) }
        if elevenLabsAvailable && source == .elevenLabs {
            rows += [.apiKey, .elevenLabsVoice, .model]
        } else {
            rows += [.macVoice, .speed, .sample]
        }
        return rows
    }

    static func footnote(elevenLabsAvailable: Bool, source: VoiceSource) -> String {
        elevenLabsAvailable && source == .elevenLabs ? elevenLabsFootnote : thisMacFootnote
    }

    var body: some View {
        let rows = Self.rows(elevenLabsAvailable: settings.elevenLabsAvailable, source: settings.voiceSource)
        SettingsSection(
            "",
            footnote: Self.footnote(elevenLabsAvailable: settings.elevenLabsAvailable, source: settings.voiceSource)
        ) {
            SettingsRow("Read aloud on replies", help: Self.switchHelp) {
                SettingsSwitch("Read aloud on replies", isOn: $settings.readAloudEnabled)
            }
            if rows.contains(.voiceSource) {
                SettingsRow("Voice source") {
                    SettingsSegmented(
                        selection: $settings.voiceSource,
                        options: VoiceSource.allCases.map { ($0, $0.label) },
                        label: "Voice source")
                }
                .disabled(!settings.readAloudEnabled)
            }
            if rows.contains(.apiKey) {
                if let account = reader.account {
                    ElevenLabsKeyRow(account: account)
                    ElevenLabsVoiceRow(account: account)
                        .disabled(!settings.readAloudEnabled)
                    ElevenLabsModelRow(account: account)
                        .disabled(!settings.readAloudEnabled)
                }
            }
            if rows.contains(.macVoice) {
                macRows
            }
        }
        .onAppear(perform: refresh)
        .task(id: reader.account?.hasKey) {
            // Load the models when the Labs tab appears and a key is saved.
            if settings.elevenLabsAvailable, let account = reader.account, account.hasKey { await account.loadModels() }
        }
    }

    @ViewBuilder
    private var macRows: some View {
        SettingsRow("Voice") {
            Picker("Voice", selection: $settings.voiceIdentifier) {
                Text(automaticLabel).tag(String?.none)
                ForEach(voices) { voice in
                    Text(voice.label).tag(Optional(voice.id))
                }
                // A chosen voice the system no longer has still shows as chosen.
                if let chosen = settings.voiceIdentifier, !voices.contains(where: { $0.id == chosen }) {
                    Text("Unavailable voice").tag(Optional(chosen))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .hoverHighlight()
        }
        .disabled(!settings.readAloudEnabled)
        SettingsRow("Speed") {
            SettingsSegmented(
                selection: $settings.speechRate,
                options: Settings.SpeechRate.allCases.map { ($0, $0.label) },
                label: "Speed")
        }
        .disabled(!settings.readAloudEnabled)
        HStack {
            personalVoiceRow
            Spacer()
            Button(reader.reading == nil ? "Play sample" : "Stop") {
                if reader.reading == nil { reader.sample() } else { reader.stop() }
            }
            .buttonStyle(SettingsButtonStyle(kind: .quiet))
            .disabled(!settings.readAloudEnabled)
        }
        .settingsRowInsets()
        if !VoiceChoices.hasNaturalVoice(voices, language: VoiceChoices.currentLanguage) {
            Text("For a natural voice, download a Premium one: System Settings › Accessibility › Spoken Content › System voice › Manage Voices… (for example Ava or Zoe, Premium). It appears here once installed.")
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .settingsRowInsets()
        }
    }

    /// "Best installed (Zoe, Premium)": with no voice chosen, Read aloud
    /// uses the best one installed for the language (`VoiceChoices.best`).
    private var automaticLabel: String {
        guard VoiceChoices.hasNaturalVoice(voices, language: VoiceChoices.currentLanguage),
            let best = VoiceChoices.best(voices, language: VoiceChoices.currentLanguage)
        else { return "System voice" }
        return "Best installed (\(best.label))"
    }

    /// Personal Voice: offered only when the person asks for it here.
    @ViewBuilder
    private var personalVoiceRow: some View {
        switch personal {
        case .notAsked:
            Button("Use my Personal Voice…") {
                Task {
                    personal = await PersonalVoiceAccess.request()
                    refresh()
                }
            }
            .buttonStyle(SettingsButtonStyle(kind: .quiet))
        case .denied:
            Text("Personal Voice is off for this app (System Settings › Privacy & Security › Personal Voice).")
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
        case .allowed, .unsupported:
            EmptyView()
        }
    }

    private func refresh() {
        personal = PersonalVoiceAccess.current
        voices = VoiceChoices.options(
            VoiceChoices.installed(), language: VoiceChoices.currentLanguage, personalAllowed: personal == .allowed)
    }
}
