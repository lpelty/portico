import SwiftUI

/// The composer's mic (v0.9 decision 1, AD1): pressing starts listening
/// into this composer and pressing again stops. While listening it is a
/// level meter on the accent. Hidden when Voice input is off (AE2).
struct MicButton: View {
    let composer: Dictation.Composer
    /// The side of the glyph's frame: 20 in the conversation, 30 on the welcome.
    var side: CGFloat = 20
    var bordered = false
    @EnvironmentObject private var dictation: Dictation
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var model: AppModel

    private var active: Bool { dictation.isActive(for: composer.id) }

    var body: some View {
        if settings.voiceInputEnabled {
            Button {
                Task { await dictation.toggle(composer) }
            } label: {
                Group {
                    if active {
                        LevelMeter(level: dictation.level, starting: dictation.phase == .starting)
                            .padding(side * 0.18)
                            .background(model.brand.accent ?? Theme.accent, in: RoundedRectangle(cornerRadius: side * 0.27, style: .continuous))
                    } else {
                        Image(systemName: "mic")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .frame(width: side, height: side)
                .overlay {
                    if bordered && !active {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help(active ? Dictation.listeningLine : "Talk: your words become text on this Mac")
            .accessibilityLabel(active ? "Stop listening" : "Talk")
            .onAppear { dictation.shown(composer) }
            .onDisappear { dictation.hidden(composer.id) }
        }
    }
}

/// Four bars that follow the microphone's level, white on the accent.
struct LevelMeter: View {
    let level: Float
    /// Still starting (the speech model may be loading): the bars rest low.
    var starting = false

    /// Each bar's share of the level, so the bars move unevenly, as speech does.
    private static let weights: [CGFloat] = [0.55, 1, 0.8, 0.4]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: geometry.size.width * 0.12) {
                ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                    Capsule()
                        .fill(.white)
                        .frame(height: max(geometry.size.height * 0.18, geometry.size.height * CGFloat(starting ? 0 : level) * weight))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.1), value: level)
        }
    }
}

/// The line beside a composer's controls while Talk is on: "Listening —
/// press again to stop" (or "release to stop" for the hold-to-talk key), or
/// for a moment why it could not start. Nil when there is nothing to say,
/// so the composer shows its usual hint.
enum DictationLine {
    @MainActor
    static func text(_ dictation: Dictation, composer id: String) -> String? {
        if dictation.isActive(for: id) {
            if dictation.phase == .starting { return "Getting ready to listen…" }
            return dictation.byHold ? Dictation.holdingLine : Dictation.listeningLine
        }
        return dictation.notice
    }
}

/// Read aloud on an agent reply (v0.9 decision 2, AD1), beside Copy and
/// shown with it on hover; "Stop reading" while it speaks (Esc stops too).
struct ReadAloudButton: View {
    let reply: String
    @EnvironmentObject private var reader: ReadAloud

    var body: some View {
        let reading = reader.isReading(reply)
        Button {
            reader.toggle(reply)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: reading ? "stop.fill" : "speaker.wave.2")
                Text(reading ? "Stop reading" : "Read aloud")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .buttonStyle(.hover)
        .help(reading ? "Stop reading (Esc)" : "Read this reply aloud; code and tables are not read")
    }
}
