import AVFoundation
import AppKit
import Foundation

// MARK: - The voice

/// What Read aloud needs from a speech synthesizer: speak one string, stop,
/// and say when an utterance ends. `AVSpeechSynthesizer` in the app
/// (`SystemSpeechSynthesizer`); a fake in the tests, so they never make a
/// sound.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Called once per utterance when it ends, finished or stopped, with
    /// the token it was started with.
    var onFinish: ((Int) -> Void)? { get set }
    func speak(_ text: String, voiceIdentifier: String?, rate: Float, token: Int)
    func stop()
}

/// `AVSpeechSynthesizer`, on-device (v0.9 decision 2). The voice is the
/// setting's when the system still has it, else the system default.
@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    var onFinish: ((Int) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var tokens = UtteranceTokens<AVSpeechUtterance>()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voiceIdentifier: String?, rate: Float, token: Int) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        utterance.rate = rate
        tokens.add(utterance, token: token)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor in self.ended(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor in self.ended(utterance) }
    }

    private func ended(_ utterance: AVSpeechUtterance) {
        guard let token = tokens.remove(utterance) else { return }
        onFinish?(token)
    }
}

/// Each utterance's token, matched by the utterance object itself: an
/// `ObjectIdentifier` can be reused by a new object once the old one is
/// freed, the object held here cannot. Pure, so it is tested.
struct UtteranceTokens<Utterance: AnyObject> {
    private var entries: [(utterance: Utterance, token: Int)] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(_ utterance: Utterance, token: Int) {
        entries.append((utterance, token))
    }

    /// The token `utterance` was spoken with, once; nil for one not held.
    mutating func remove(_ utterance: Utterance) -> Int? {
        guard let index = entries.firstIndex(where: { $0.utterance === utterance }) else { return nil }
        return entries.remove(at: index).token
    }
}

// MARK: - Read aloud

/// Read aloud on a reply (v0.9 decision 2, AD1): one reply at a time.
/// Starting another stops the current one; Stop, a second press, or Esc
/// stops it. Reads `SpeakableText`, never the code. A reply is known by
/// its message's id when it has one, so two replies with the same words
/// are told apart and a reply still streaming stays the one reading.
@MainActor
final class ReadAloud: ObservableObject {
    /// The reply being read: its key (the message's id, else its Markdown
    /// as received), nil when silent.
    @Published private(set) var reading: String?

    private let settings: Settings
    private let synthesizer: SpeechSynthesizing
    private let escape: EscapeKey
    private var token = 0

    /// The installed voices, read when speaking starts (a fake in tests).
    private let installedVoices: () -> [VoiceOption]

    init(
        settings: Settings, synthesizer: SpeechSynthesizing? = nil, escape: EscapeKey? = nil,
        installedVoices: @escaping () -> [VoiceOption] = VoiceChoices.installed
    ) {
        self.installedVoices = installedVoices
        self.settings = settings
        self.synthesizer = synthesizer ?? SystemSpeechSynthesizer()
        self.escape = escape ?? EscapeKey()
        self.synthesizer.onFinish = { [weak self] token in self?.finished(token) }
    }

    /// Whether the reply known by `key` (its message's id, else its text) is reading.
    func isReading(_ key: String) -> Bool { reading == key }

    /// The reply's button: read it, or stop it when it is the one reading.
    func toggle(_ reply: String, key: String? = nil) {
        let key = key ?? reply
        if isReading(key) { stop() } else { read(reply, key: key) }
    }

    /// Reads `reply` (its speakable text), stopping whatever was reading.
    /// A reply with nothing to say stays silent.
    func read(_ reply: String, key: String? = nil) {
        stop()
        let speech = SpeakableText.speech(fromMarkdown: reply)
        guard !speech.isEmpty else { return }
        token += 1
        reading = key ?? reply
        escape.watch { [weak self] in self?.stop() }
        synthesizer.speak(speech, voiceIdentifier: voice, rate: settings.speechRate.utteranceRate, token: token)
    }

    /// The chosen voice, or the best installed one (`VoiceChoices.resolved`).
    private var voice: String? {
        VoiceChoices.resolved(chosen: settings.voiceIdentifier, installed: installedVoices(), language: VoiceChoices.currentLanguage)
    }

    /// Speaks a line for the Voice pane's sample with the chosen voice and speed.
    func sample() {
        read("This is how replies will sound.")
    }

    func stop() {
        guard reading != nil else { return }
        reading = nil
        escape.unwatch()
        synthesizer.stop()
    }

    /// An utterance ended; an older one (stopped for a newer) changes nothing.
    private func finished(_ ended: Int) {
        guard ended == token, reading != nil else { return }
        reading = nil
        escape.unwatch()
    }
}

// MARK: - Esc

/// Esc, while something is reading or listening, stops it (v0.9 decisions
/// 1, 2): a local key monitor, in place only while there is something to
/// stop, that takes the key so it does not also reach the focused view.
@MainActor
final class EscapeKey {
    static let keyCode: UInt16 = 53
    private var monitor: Any?
    private var action: (() -> Void)?

    var isWatching: Bool { action != nil }

    func watch(_ action: @escaping () -> Void) {
        self.action = action
        guard monitor == nil, NSApp != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == EscapeKey.keyCode
            let taken = isEscape && MainActor.assumeIsolated { self?.press() ?? false }
            return taken ? nil : event
        }
    }

    func unwatch() {
        action = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Esc was pressed: runs the action, if any; true when it was taken.
    @discardableResult
    func press() -> Bool {
        guard let action else { return false }
        action()
        return true
    }
}

// MARK: - Voices

/// One voice as the Voice pane lists it.
struct VoiceOption: Equatable, Sendable, Identifiable {
    enum Quality: Int, Sendable { case standard, enhanced, premium }

    var id: String
    var name: String
    var language: String
    var quality: Quality = .standard
    var personal = false
    var novelty = false

    var label: String {
        if personal { return "\(name) (Personal Voice)" }
        switch quality {
        case .standard: return name
        case .enhanced: return "\(name) (Enhanced)"
        case .premium: return "\(name) (Premium)"
        }
    }
}

/// The voices offered (AE2): the system voices in the person's language,
/// the novelty voices left out, plus their Personal Voice only when they
/// have allowed Portico to use it. Pure over the voice list.
enum VoiceChoices {
    static func options(_ voices: [VoiceOption], language: String, personalAllowed: Bool) -> [VoiceOption] {
        let wanted = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        return voices
            .filter { voice in
                if voice.novelty { return false }
                if voice.personal { return personalAllowed }
                let code = voice.language.lowercased().split(separator: "-").first.map(String.init) ?? ""
                return wanted.isEmpty || code == wanted
            }
            .sorted { a, b in
                if a.personal != b.personal { return a.personal }
                if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return a.quality.rawValue > b.quality.rawValue
            }
    }

    /// The best voice installed for `language`, Personal Voice aside:
    /// Premium, then Enhanced, then the rest (v0.9: the system default is
    /// often a compact voice, which sounds dated).
    static func best(_ voices: [VoiceOption], language: String) -> VoiceOption? {
        options(voices, language: language, personalAllowed: false)
            .max { a, b in
                if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
                return a.name.localizedStandardCompare(b.name) == .orderedDescending
            }
    }

    /// The voice Read aloud uses: the chosen one while it is installed,
    /// else the best installed Enhanced or Premium one; nil leaves it to the
    /// system.
    static func resolved(chosen: String?, installed: [VoiceOption], language: String) -> String? {
        if let chosen, installed.contains(where: { $0.id == chosen }) { return chosen }
        // Only a natural voice beats the system's own choice; among compact
        // voices the system knows the person's region best.
        guard hasNaturalVoice(installed, language: language) else { return nil }
        return best(installed, language: language)?.id
    }

    /// Whether an Enhanced or Premium voice is installed for `language`;
    /// without one the Voice pane says where to get one.
    static func hasNaturalVoice(_ voices: [VoiceOption], language: String) -> Bool {
        (best(voices, language: language)?.quality.rawValue ?? 0) >= VoiceOption.Quality.enhanced.rawValue
    }

    /// The system's voices, as options.
    static func installed() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            VoiceOption(
                id: voice.identifier, name: voice.name, language: voice.language,
                quality: voice.quality == .premium ? .premium : voice.quality == .enhanced ? .enhanced : .standard,
                personal: voice.voiceTraits.contains(.isPersonalVoice),
                novelty: voice.voiceTraits.contains(.isNoveltyVoice))
        }
    }

    /// The person's language, as voices name it (`en`).
    static var currentLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}

/// Personal Voice permission as the Voice pane shows it. Reading the status
/// never asks; only the pane's button asks (v0.9 decision 2).
enum PersonalVoiceAccess: Equatable, Sendable {
    case allowed, notAsked, denied, unsupported

    init(_ status: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus) {
        switch status {
        case .authorized: self = .allowed
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        default: self = .unsupported
        }
    }

    static var current: PersonalVoiceAccess {
        PersonalVoiceAccess(AVSpeechSynthesizer.personalVoiceAuthorizationStatus)
    }

    /// Asks the system once; the answer comes back on the main actor.
    static func request() async -> PersonalVoiceAccess {
        PersonalVoiceAccess(await askSystem())
    }

    /// The system answers on its own queue; the callback must not inherit
    /// the main actor (a run-time isolation check would stop the app).
    private nonisolated static func askSystem() async -> AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus {
        await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}
