import SwiftUI

/// v0.26 (PORT-23, ZG1): Read aloud's rows when the voice source is
/// ElevenLabs: the API key (ruling 9), the voice (ruling 10) with Choose…,
/// and the model. The key is typed into a secure field, saved to the
/// Keychain and never shown again.
struct ElevenLabsKeyRow: View {
    @ObservedObject var account: ElevenLabsAccount
    @State private var replacing = false
    @State private var typed = ""
    @State private var error: String?

    static let subtitle = "Kept in this Mac's Keychain. Never in a config file, and never seen by the agent."

    var body: some View {
        SettingsRow("API key", help: error ?? Self.subtitle) {
            if account.hasKey && !replacing {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(Theme.iconFont(12))
                        .foregroundStyle(Theme.working)
                        .accessibilityHidden(true)
                    Text("Saved")
                        .scaledFont(13)
                        .foregroundStyle(Theme.text2)
                    Button("Replace…") { replacing = true; typed = ""; error = nil }
                        .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    Button("Remove") {
                        do { try account.removeKey() } catch { self.error = "The key couldn't be removed." }
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Paste your API key", text: $typed)
                        .textFieldStyle(.plain)
                        .scaledFont(13)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(width: 200)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(SettingsButtonStyle(kind: .accent))
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if replacing {
                        Button("Cancel") { replacing = false; typed = ""; error = nil }
                            .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    }
                }
            }
        }
    }

    private func save() {
        do {
            try account.saveKey(typed)
            typed = ""
            replacing = false
            error = nil
        } catch SecretStoreError.empty {
            error = "Paste a key first."
        } catch {
            self.error = "The key couldn't be saved in the Keychain."
        }
    }
}

/// The voice: an ID field ("<name> · <ID>" when not editing and the name is
/// known), and Choose…, the account's voices by name.
struct ElevenLabsVoiceRow: View {
    @ObservedObject var account: ElevenLabsAccount
    @EnvironmentObject private var settings: Settings
    @FocusState private var editing: Bool
    @State private var text = ""
    @State private var choosing = false

    /// What the field shows (ruling 10).
    static func shown(id: String?, name: String?, editing: Bool) -> String {
        guard let id else { return "" }
        if !editing, let name, !name.isEmpty { return "\(name) · \(id)" }
        return id
    }

    var body: some View {
        SettingsRow("Voice") {
            HStack(spacing: 8) {
                TextField("Voice ID", text: $text)
                    .textFieldStyle(.plain)
                    .scaledFont(13)
                    .focused($editing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 240)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .onSubmit { editing = false }
                Button("Choose…") { choosing = true }
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    .disabled(!account.hasKey)
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        ElevenLabsVoicePicker(account: account) { voice in
                            settings.elevenLabsVoiceID = voice.id
                            settings.elevenLabsVoiceName = voice.name
                            text = Self.shown(id: voice.id, name: voice.name, editing: false)
                            choosing = false
                        }
                        .popoverSurface()
                    }
            }
        }
        .onAppear { text = Self.shown(id: settings.elevenLabsVoiceID, name: settings.elevenLabsVoiceName, editing: false) }
        .onChange(of: editing) { _, now in
            text = Self.shown(id: settings.elevenLabsVoiceID, name: settings.elevenLabsVoiceName, editing: now)
        }
        .onChange(of: text) { _, new in
            guard editing else { return }
            let id = new.trimmingCharacters(in: .whitespacesAndNewlines)
            let newID: String? = id.isEmpty ? nil : id
            if newID != settings.elevenLabsVoiceID {
                settings.elevenLabsVoiceID = newID
                settings.elevenLabsVoiceName = nil  // editing the ID forgets the name
            }
        }
    }
}

/// Choose…'s list: the account's voices by name, or why there are none.
struct ElevenLabsVoicePicker: View {
    @ObservedObject var account: ElevenLabsAccount
    let onChoose: (ElevenLabsVoice) -> Void
    @State private var voices: [ElevenLabsVoice]?
    @State private var failure: ElevenLabsFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure {
                Text(failure.reason)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text2)
                    .padding(12)
            } else if let voices {
                if voices.isEmpty {
                    Text("This account has no voices.")
                        .scaledFont(12)
                        .foregroundStyle(Theme.text2)
                        .padding(12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(voices) { voice in
                                Button { onChoose(voice) } label: {
                                    Text(voice.name)
                                        .scaledFont(13)
                                        .foregroundStyle(Theme.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(HoverButtonStyle())
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 280)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(16)
            }
        }
        .frame(width: 240)
        .task {
            do throws(ElevenLabsFailure) { voices = try await account.voices() } catch { failure = error }
        }
    }
}

/// The model: a menu over the account's models; a chosen ID that isn't listed still shows.
struct ElevenLabsModelRow: View {
    @ObservedObject var account: ElevenLabsAccount
    @EnvironmentObject private var settings: Settings

    var body: some View {
        SettingsRow("Model") {
            Picker("Model", selection: $settings.elevenLabsModel) {
                ForEach(account.models) { model in
                    Text(model.id).tag(model.id)
                }
                if !account.models.contains(where: { $0.id == settings.elevenLabsModel }) {
                    Text(settings.elevenLabsModel).tag(settings.elevenLabsModel)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .hoverHighlight()
        }
    }
}
