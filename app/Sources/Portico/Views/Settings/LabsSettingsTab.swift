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

/// One Labs item: the header row, the note, the box.
private struct LabItemBlock: View {
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
            if item.key == LabItem.readAloudKey {
                ReadAloudControls()
            } else {
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

/// Preview (accent on accentSoft) or Local (text2 on control), solid.
private struct LabTagPill: View {
    let tag: LabItem.Tag

    var body: some View {
        Text(tag == .preview ? "Preview" : "Local")
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

    var body: some View {
        SettingsSection(
            "",
            footnote: "Read aloud speaks a reply's spoken summary when the agent marks one, otherwise its text. Code and tables are never read; you hear \"See the code below.\" Esc stops reading."
        ) {
            SettingsRow("Read aloud on replies", help: Self.switchHelp) {
                SettingsSwitch("Read aloud on replies", isOn: $settings.readAloudEnabled)
            }
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
        .onAppear(perform: refresh)
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
