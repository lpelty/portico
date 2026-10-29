import SwiftUI

/// Settings › Voice (v0.9 decision 7, AE2): Talk (voice input, send when
/// I stop talking, the hold-to-talk key) and Listen (Read aloud, the voice,
/// the speed). Everything here runs on this Mac.
struct VoiceSettingsTab: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var reader: ReadAloud
    @State private var voices: [VoiceOption] = []
    @State private var personal: PersonalVoiceAccess = .unsupported

    var body: some View {
        Form {
            Section("Talk") {
                Toggle("Voice input", isOn: $settings.voiceInputEnabled)
                Toggle("Send when I stop talking", isOn: $settings.sendWhenStopTalking)
                    .disabled(!settings.voiceInputEnabled)
                Picker("Hold-to-talk shortcut", selection: $settings.holdToTalk) {
                    ForEach(Settings.HoldToTalk.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                .disabled(!settings.voiceInputEnabled)
                Text("Press the mic in the message box and speak; press it again, or Esc, to stop. Your words appear as you speak and are turned into text on this Mac. The first time, macOS asks to allow the microphone and speech recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Hidden behind a flag for now (Settings.readAloudAvailable).
            if settings.readAloudAvailable {
                Section("Listen") {
                    Toggle("Read aloud on replies", isOn: $settings.readAloudEnabled)
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
                    .disabled(!settings.readAloudEnabled)
                    Picker("Speed", selection: $settings.speechRate) {
                        ForEach(Settings.SpeechRate.allCases, id: \.self) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.readAloudEnabled)
                    HStack {
                        personalVoiceRow
                        Spacer()
                        Button(reader.reading == nil ? "Play sample" : "Stop") {
                            if reader.reading == nil { reader.sample() } else { reader.stop() }
                        }
                        .disabled(!settings.readAloudEnabled)
                    }
                    if !VoiceChoices.hasNaturalVoice(voices, language: VoiceChoices.currentLanguage) {
                        Text("For a natural voice, download a Premium one: System Settings › Accessibility › Spoken Content › System voice › Manage Voices… (for example Ava or Zoe, Premium). It appears here once installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Read aloud speaks a reply's spoken summary when the agent marks one, otherwise its text. Code and tables are never read; you hear \"See the code below.\" Esc stops reading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
        case .denied:
            Text("Personal Voice is off for this app (System Settings › Privacy & Security › Personal Voice).")
                .font(.caption)
                .foregroundStyle(.secondary)
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
