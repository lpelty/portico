import AppKit
import Foundation

// MARK: - The recogniser

/// What was heard so far: the finalised text and the part still being
/// recognised (it may change before it is final).
struct Transcript: Equatable, Sendable {
    var finalized = ""
    var volatile = ""

    var text: String { DictationText.joined([finalized, volatile]) }
}

/// What Talk needs from on-device transcription (v0.9 decision 1): start
/// listening, report the transcript and the input level as they change,
/// stop and finalise. `AnalyzerTranscriber` in the app; a fake in the
/// tests, so they never touch the microphone.
@MainActor
protocol SpeechTranscribing: AnyObject {
    /// Starts the microphone and the transcriber; throws when either cannot start.
    func start(
        update: @escaping @MainActor (Transcript) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) async throws
    /// Stops the microphone and returns once the last words are final.
    func stop() async
}

/// A permission's state, as Talk reads it.
enum VoicePermission: Equatable, Sendable { case granted, denied, notAsked }

/// The microphone and speech recognition permissions. Asked only when the
/// person first presses the mic (decision 1); a fake in the tests.
@MainActor
protocol VoicePermissions {
    var microphone: VoicePermission { get }
    var speech: VoicePermission { get }
    func requestMicrophone() async -> Bool
    func requestSpeech() async -> Bool
}

// MARK: - Pure parts

/// Where Talk's words go in the composer. Pure, so it is tested.
enum DictationText {
    /// What the composer held when listening began, ready for words to
    /// follow it: a space after text that does not end in one.
    static func prefix(for existing: String) -> String {
        guard let last = existing.last, !last.isWhitespace else { return existing }
        return existing + " "
    }

    /// Segments as one string: a space between two that would otherwise
    /// run together, none before punctuation; no space at the start.
    static func joined(_ segments: [String]) -> String {
        var out = ""
        for segment in segments where !segment.isEmpty {
            if let last = out.last, let first = segment.first,
                !last.isWhitespace, !first.isWhitespace, !".,!?;:)…".contains(first)
            {
                out += " "
            }
            out += segment
        }
        return String(out.drop { $0.isWhitespace })
    }

    /// The composer's text while listening.
    static func composed(prefix: String, transcript: Transcript) -> String {
        prefix + transcript.text
    }
}

/// Whether voice input can ask for the microphone at all (v0.9 task 4). A
/// `swift run` build has no bundle Info.plist, and asking for the
/// microphone without `NSMicrophoneUsageDescription` gets the process
/// killed by the system's privacy checks, so Talk says why instead.
enum VoiceInputGuard {
    static let needsInstalledApp = "Voice input needs the installed app (bin/install)."
    static let usageKeys = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]

    /// Nil when it may ask; else the line to show. `info` reads the
    /// bundle's Info.plist (injectable for the tests).
    static func problem(info: (String) -> Any?) -> String? {
        for key in usageKeys {
            guard let text = info(key) as? String, !text.isEmpty else { return needsInstalledApp }
        }
        return nil
    }

    static func bundleInfo(_ key: String) -> Any? {
        Bundle.main.object(forInfoDictionaryKey: key)
    }
}

/// Hold-to-talk (v0.9 decision 1): the chosen key held for a moment
/// starts listening and its release stops it. A key typed while it is
/// down (Option+E for an accent) means it was a modifier, not a talk: before
/// listening nothing starts, and once listening the talk is cancelled.
/// Pure state, fed by the key monitor; tested.
struct HoldToTalkTracker: Equatable {
    enum Action: Equatable { case none, arm, begin, end, cancel }
    enum State: Equatable { case idle, armed, holding, spoiled }

    /// Right Option's key code.
    static let rightOptionKeyCode: UInt16 = 61
    /// Right Option's own bit in a key event's raw modifier flags
    /// (`NX_DEVICERALTKEYMASK`): `.option` stays set while Left Option is
    /// held, so it cannot say that Right Option went up.
    static let rightOptionMask: UInt = 0x40
    /// How long the key is held before listening starts.
    static let holdDelay: Duration = .milliseconds(300)

    private(set) var state: State = .idle

    /// A modifier changed: `keyCode` is the key, `flags` the event's raw
    /// modifier flags (`NSEvent.modifierFlags.rawValue`).
    mutating func flagsChanged(keyCode: UInt16, flags: UInt, shortcut: Settings.HoldToTalk) -> Action {
        guard shortcut == .rightOption, keyCode == Self.rightOptionKeyCode else { return .none }
        if flags & Self.rightOptionMask != 0 {
            guard state == .idle else { return .none }
            state = .armed
            return .arm
        }
        let was = state
        state = .idle
        return was == .holding ? .end : .none
    }

    /// Another key went down while the shortcut was held: `.cancel` when
    /// listening had begun.
    @discardableResult
    mutating func keyDown() -> Action {
        switch state {
        case .armed:
            state = .spoiled
            return .none
        case .holding:
            state = .spoiled
            return .cancel
        case .idle, .spoiled:
            return .none
        }
    }

    /// The hold delay passed: listening starts if the key is still held alone.
    mutating func delayElapsed() -> Action {
        guard state == .armed else { return .none }
        state = .holding
        return .begin
    }
}

// MARK: - Talk

/// Talk into a composer (v0.9 decision 1, AD1). Pressing the mic starts
/// on-device transcription and the words land in the composer as they
/// are recognised, after what was already typed; pressing again, Esc, or
/// releasing the hold-to-talk key stops. With "Send when I stop talking"
/// a stop by the mic or the key sends; Esc never sends, it only stops.
/// Permissions are asked on the first press, never before.
///
/// A talk writes only into a composer it still owns: sending from it, the
/// composer going away, or the person editing its text ends the talk
/// without sending, and nothing more is written there.
@MainActor
final class Dictation: ObservableObject {
    enum Phase: Equatable { case idle, starting, listening, finishing }

    /// A composer Talk can fill: the conversation's, or the welcome's.
    struct Composer {
        /// "start" for the welcome, "chat-N" for a conversation.
        let id: String
        let text: () -> String
        let setText: (String) -> Void
        /// Sends what is in the composer, when it can be sent.
        let send: () -> Void
        /// The mic button showing it: a composer made again for the same
        /// chat is told apart from the one going away.
        var instance: UUID? = nil

        func shown(by instance: UUID) -> Composer {
            var composer = self
            composer.instance = instance
            return composer
        }
    }

    static let listeningLine = "Listening — press again to stop"
    static let holdingLine = "Listening — release to stop"
    static let noticeSeconds: Double = 6

    @Published private(set) var phase: Phase = .idle
    /// The composer being filled, while starting, listening or finishing.
    @Published private(set) var target: String?
    /// The input level, 0–1, for the meter.
    @Published private(set) var level: Float = 0
    /// A one-line reason Talk could not start or stopped, shown for a moment.
    @Published private(set) var notice: String?
    /// Whether listening came from the hold-to-talk key (the line says "release").
    @Published private(set) var byHold = false

    /// One talk, from the press to its end. Every callback is checked
    /// against the current talk, so an old one ending late changes nothing.
    private final class Talk {
        let composer: Composer
        let byHold: Bool
        /// What the composer held when the talk began.
        let original: String
        let prefix: String
        var transcriber: SpeechTranscribing?
        /// The composer's text as Talk last left it. Anything else means the
        /// person edited it, or it was sent or cleared.
        var written: String
        /// Nothing more goes into the composer, and nothing is sent.
        var detached = false
        /// `stop` was called on the transcriber.
        var stopping = false

        init(composer: Composer, byHold: Bool) {
            self.composer = composer
            self.byHold = byHold
            original = composer.text()
            prefix = DictationText.prefix(for: original)
            written = original
        }
    }

    private let settings: Settings
    private let makeTranscriber: () -> SpeechTranscribing?
    private let permissions: VoicePermissions
    private let info: (String) -> Any?
    private let escape: EscapeKey
    private var talk: Talk?
    /// The composers shown, last shown last: where hold-to-talk sends its words.
    private var shown: [Composer] = []
    private var hold = HoldToTalkTracker()
    private var keyMonitor: Any?
    private var noticeTask: Task<Void, Never>?

    init(
        settings: Settings,
        transcriber: (() -> SpeechTranscribing?)? = nil,
        permissions: VoicePermissions? = nil,
        info: @escaping (String) -> Any? = VoiceInputGuard.bundleInfo,
        escape: EscapeKey? = nil
    ) {
        self.settings = settings
        self.makeTranscriber = transcriber ?? OnDeviceTranscription.make
        self.permissions = permissions ?? SystemVoicePermissions()
        self.info = info
        self.escape = escape ?? EscapeKey()
    }

    func isActive(for id: String) -> Bool { target == id && phase != .idle }

    /// The mic button: start listening into `composer`, or stop when it is
    /// the one listening (sending if the setting says so).
    func toggle(_ composer: Composer) async {
        if isActive(for: composer.id) {
            await stop(sending: settings.sendWhenStopTalking)
        } else {
            await start(composer)
        }
    }

    func start(_ composer: Composer, byHold: Bool = false) async {
        // The last talk is still ending: one at a time.
        guard phase != .finishing else { return }
        if let talk {
            guard talk.composer.id != composer.id else { return }
            await finish(talk, sending: false)
            guard self.talk == nil else { return }
        }
        if let problem = VoiceInputGuard.problem(info: info) { return show(problem) }
        clearNotice()
        // The talk is the composer's from the press on, before any wait: a
        // second press, or the hold key's release, ends it while it starts.
        let talk = Talk(composer: composer, byHold: byHold)
        self.talk = talk
        self.byHold = byHold
        target = composer.id
        phase = .starting
        if let problem = await askPermissions() {
            guard self.talk === talk else { return }
            reset()
            return show(problem)
        }
        // Stopped while the permission prompt was up.
        guard self.talk === talk else { return }
        guard let transcriber = makeTranscriber() else {
            reset()
            return show("Voice input needs macOS 26 or later.")
        }
        talk.transcriber = transcriber
        do {
            try await transcriber.start(
                update: { [weak self, weak talk] transcript in
                    if let talk { self?.heard(transcript, in: talk) }
                },
                level: { [weak self, weak talk] level in
                    guard let self, let talk, self.talk === talk else { return }
                    self.level = level
                },
                failed: { [weak self, weak talk] message in
                    if let talk { self?.failed(message, in: talk) }
                })
        } catch {
            guard self.talk === talk else { return }
            reset()
            return show(Self.message(for: error))
        }
        // Ended while it was starting: the transcriber stops too.
        guard self.talk === talk, phase == .starting else {
            if !talk.stopping {
                talk.stopping = true
                await transcriber.stop()
            }
            return
        }
        phase = .listening
        escape.watch { [weak self, weak talk] in
            guard let self, let talk else { return }
            Task { await self.finish(talk, sending: false) }
        }
    }

    /// Stops listening; the words stay in the composer, and are sent when `sending`.
    func stop(sending: Bool) async {
        guard let talk else { return }
        await finish(talk, sending: sending)
    }

    /// The composer `id` is about to send what it holds: a talk into it
    /// ends first, without sending, and writes nothing more there.
    func willSend(from id: String) {
        guard let talk, talk.composer.id == id else { return }
        release(talk)
    }

    /// The main window closed or the app is quitting: any talk ends, unsent.
    func cancel() async {
        guard let talk else { return }
        talk.detached = true
        await finish(talk, sending: false)
    }

    // MARK: composers shown

    /// A composer appeared: hold-to-talk fills it from now on.
    func shown(_ composer: Composer) {
        shown.removeAll { $0.id == composer.id && $0.instance == composer.instance }
        shown.append(composer)
        installKeyMonitor()
    }

    /// A composer went away (another conversation, Document View, the
    /// welcome becoming a conversation): a talk into it ends, unsent. Only
    /// the same instance counts, so a composer made again for the same
    /// chat, shown before the old one is hidden, keeps its talk.
    func hidden(_ id: String, instance: UUID? = nil) {
        shown.removeAll { $0.id == id && $0.instance == instance }
        guard let talk, talk.composer.id == id, talk.composer.instance == instance else { return }
        release(talk)
    }

    // MARK: inside

    /// Ends `talk` and then stops its transcriber: an orderly stop sends
    /// when `sending` and something could have been heard.
    private func finish(_ talk: Talk, sending: Bool) async {
        guard self.talk === talk, phase == .starting || phase == .listening else { return }
        // Nothing can have been heard before listening began.
        let listened = phase == .listening
        phase = .finishing
        escape.unwatch()
        if let transcriber = talk.transcriber, !talk.stopping {
            talk.stopping = true
            await transcriber.stop()
        }
        guard self.talk === talk else { return }
        reset()
        let composer = talk.composer
        if sending, listened, !talk.detached,
            !composer.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            composer.send()
        }
    }

    /// Lets go of `talk`'s composer at once (nothing more written, nothing
    /// sent); the transcriber stops behind.
    private func release(_ talk: Talk) {
        talk.detached = true
        Task { await finish(talk, sending: false) }
    }

    private func heard(_ transcript: Transcript, in talk: Talk) {
        guard self.talk === talk, !talk.detached else { return }
        let composer = talk.composer
        // The person typed, or the text was sent or cleared: theirs stays.
        guard composer.text() == talk.written else { return release(talk) }
        composer.setText(DictationText.composed(prefix: talk.prefix, transcript: transcript))
        talk.written = composer.text()
    }

    private func failed(_ message: String, in talk: Talk) {
        guard self.talk === talk, phase == .starting || phase == .listening else { return }
        show(message)
        Task { await finish(talk, sending: false) }
    }

    private func reset() {
        talk = nil
        target = nil
        phase = .idle
        level = 0
        byHold = false
    }

    /// Asks for what has not been asked yet; a reason when one is refused.
    private func askPermissions() async -> String? {
        switch permissions.microphone {
        case .denied: return Self.microphoneOff
        case .notAsked: if await !permissions.requestMicrophone() { return Self.microphoneOff }
        case .granted: break
        }
        switch permissions.speech {
        case .denied: return Self.speechOff
        case .notAsked: if await !permissions.requestSpeech() { return Self.speechOff }
        case .granted: break
        }
        return nil
    }

    static let microphoneOff = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
    static let speechOff = "Speech recognition is off. Turn it on in System Settings › Privacy & Security › Speech Recognition."

    static func message(for error: Error) -> String {
        if let error = error as? TalkError { return error.message }
        return "Voice input could not start: \(error.localizedDescription)"
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    // MARK: hold-to-talk

    /// Hold-to-talk's key, seen by the app's own windows only.
    private func installKeyMonitor() {
        guard keyMonitor == nil, NSApp != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown {
                    self.keyDown()
                } else {
                    self.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue)
                }
            }
            return event
        }
    }

    /// The hold-to-talk key went down or up; `flags` are the event's raw
    /// modifier flags (internal for the tests).
    func flagsChanged(keyCode: UInt16, flags: UInt) {
        switch hold.flagsChanged(keyCode: keyCode, flags: flags, shortcut: settings.holdToTalk) {
        case .arm:
            Task { [weak self] in
                try? await Task.sleep(for: HoldToTalkTracker.holdDelay)
                await self?.holdDelayElapsed()
            }
        case .end:
            // Only a talk the key began; a press of the mic is the mic's to stop.
            guard let talk, talk.byHold else { return }
            Task { await finish(talk, sending: settings.sendWhenStopTalking) }
        case .none, .begin, .cancel:
            break
        }
    }

    /// A key went down (internal for the tests). Typed while the hold key
    /// is down, it was a modifier after all (Option+E): the talk is
    /// cancelled, its words go, and the composer holds what it held before.
    func keyDown() {
        guard hold.keyDown() == .cancel, let talk, talk.byHold, !talk.detached else { return }
        if talk.composer.text() == talk.written { talk.composer.setText(talk.original) }
        release(talk)
    }

    func holdDelayElapsed() async {
        guard hold.delayElapsed() == .begin else { return }
        guard settings.voiceInputEnabled, let composer = shown.last, phase == .idle else { return }
        await start(composer, byHold: true)
    }
}

/// A reason Talk could not start, worded for the person.
struct TalkError: Error, Equatable {
    let message: String
}
