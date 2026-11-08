import SwiftUI

/// Settings › Voice (v0.9 decision 7, AE2): Talk (voice input, send when
/// I stop talking, the hold-to-talk key). Everything here runs on this Mac.
/// Drawn with the kit (v0.19 §3). v0.25 §2.2: Read aloud's section moved to
/// Settings › Labs (`ReadAloudControls`) until it is released.
struct VoiceSettingsTab: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Talk",
                footnote: "Press the mic in the message box and speak; press it again, or Esc, to stop. Your words appear as you speak and are turned into text on this Mac. The first time, macOS asks to allow the microphone and speech recognition."
            ) {
                SettingsRow("Voice input") {
                    SettingsSwitch("Voice input", isOn: $settings.voiceInputEnabled)
                }
                SettingsRow("Send when I stop talking") {
                    SettingsSwitch("Send when I stop talking", isOn: $settings.sendWhenStopTalking)
                }
                .disabled(!settings.voiceInputEnabled)
                SettingsRow("Hold-to-talk shortcut") {
                    Picker("Hold-to-talk shortcut", selection: $settings.holdToTalk) {
                        ForEach(Settings.HoldToTalk.allCases, id: \.self) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .hoverHighlight()
                }
                .disabled(!settings.voiceInputEnabled)
            }
        }
    }
}
