import AppKit
import XCTest

@testable import Portico

// MARK: - Fakes (no microphone, no voice)

@MainActor
private final class FakeTranscriber: SpeechTranscribing {
    var startError: Error?
    private(set) var starts = 0
    private(set) var stops = 0
    var update: (@MainActor (Transcript) -> Void)?
    var level: (@MainActor (Float) -> Void)?
    var failed: (@MainActor (String) -> Void)?
    /// The next start waits (after taking its callbacks) until `resumeStart`.
    var suspendNextStart = false
    /// Stops wait until `resumeStops`, as finalising takes a moment.
    var holdStops = false
    private var startGate: CheckedContinuation<Void, Never>?
    private var stopGates: [CheckedContinuation<Void, Never>] = []

    var isStartSuspended: Bool { startGate != nil }

    func start(
        update: @escaping @MainActor (Transcript) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) async throws {
        starts += 1
        if let startError { throw startError }
        self.update = update
        self.level = level
        self.failed = failed
        if suspendNextStart {
            suspendNextStart = false
            await withCheckedContinuation { startGate = $0 }
        }
    }

    func stop() async {
        stops += 1
        if holdStops { await withCheckedContinuation { stopGates.append($0) } }
    }

    func resumeStart() {
        startGate?.resume()
        startGate = nil
    }

    func resumeStops() {
        holdStops = false
        stopGates.forEach { $0.resume() }
        stopGates = []
    }
}

@MainActor
private final class FakePermissions: VoicePermissions {
    var microphone: VoicePermission = .notAsked
    var speech: VoicePermission = .notAsked
    var grantMicrophone = true
    var grantSpeech = true
    /// The microphone prompt stays up until `answer`.
    var promptStaysUp = false
    private(set) var asked: [String] = []
    private var prompt: CheckedContinuation<Void, Never>?

    var isPromptUp: Bool { prompt != nil }

    func requestMicrophone() async -> Bool {
        asked.append("microphone")
        if promptStaysUp { await withCheckedContinuation { prompt = $0 } }
        microphone = grantMicrophone ? .granted : .denied
        return grantMicrophone
    }

    func answer() {
        prompt?.resume()
        prompt = nil
    }

    func requestSpeech() async -> Bool {
        asked.append("speech")
        speech = grantSpeech ? .granted : .denied
        return grantSpeech
    }
}

@MainActor
private final class FakeSynthesizer: SpeechSynthesizing {
    var onFinish: ((Int) -> Void)?
    private(set) var spoken: [(text: String, voice: String?, rate: Float, token: Int)] = []
    private(set) var stops = 0

    func speak(_ text: String, voiceIdentifier: String?, rate: Float, token: Int) {
        spoken.append((text, voiceIdentifier, rate, token))
    }

    func stop() {
        stops += 1
        // As AVSpeechSynthesizer does: the stopped utterance reports that it ended.
        if let last = spoken.last { onFinish?(last.token) }
    }

    func finishLast() {
        if let last = spoken.last { onFinish?(last.token) }
    }
}

/// A composer backed by a string, recording sends.
@MainActor
private final class FakeComposer {
    var text: String
    var sends: [String] = []
    let id: String

    init(_ id: String = "chat-1", text: String = "") {
        self.id = id
        self.text = text
    }

    var composer: Dictation.Composer {
        Dictation.Composer(
            id: id, text: { self.text }, setText: { self.text = $0 }, send: { self.sends.append(self.text) })
    }
}

private func bundled(_ key: String) -> Any? { VoiceInputGuard.usageKeys.contains(key) ? "why" : nil }

/// Raw modifier flags as a key event carries them.
private let option = NSEvent.ModifierFlags.option.rawValue
private let rightOptionDown = HoldToTalkTracker.rightOptionMask | option
/// Left Option's own bit (`NX_DEVICELALTKEYMASK`).
private let leftOptionDown: UInt = 0x20 | option

/// Lets tasks the code under test started run, until `done` (or a while).
@MainActor
private func settle(until done: () -> Bool) async {
    for _ in 0..<200 where !done() { await Task.yield() }
}

// MARK: - Settings

@MainActor
final class VoiceSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "VoiceSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaults() {
        let settings = Settings(defaults: defaults())
        XCTAssertTrue(settings.voiceInputEnabled)
        XCTAssertFalse(settings.sendWhenStopTalking)
        XCTAssertEqual(settings.holdToTalk, .none)
        XCTAssertTrue(settings.readAloudEnabled)
        XCTAssertNil(settings.voiceIdentifier)
        XCTAssertEqual(settings.speechRate, .normal)
    }

    func testVoiceSettingsPersist() {
        let store = defaults()
        let settings = Settings(defaults: store)
        settings.voiceInputEnabled = false
        settings.sendWhenStopTalking = true
        settings.holdToTalk = .rightOption
        settings.readAloudEnabled = false
        settings.voiceIdentifier = "com.example.voice"
        settings.speechRate = .fast
        let again = Settings(defaults: store)
        XCTAssertFalse(again.voiceInputEnabled)
        XCTAssertTrue(again.sendWhenStopTalking)
        XCTAssertEqual(again.holdToTalk, .rightOption)
        XCTAssertFalse(again.readAloudEnabled)
        XCTAssertEqual(again.voiceIdentifier, "com.example.voice")
        XCTAssertEqual(again.speechRate, .fast)
        again.voiceIdentifier = nil
        XCTAssertNil(Settings(defaults: store).voiceIdentifier)
    }

    func testSpeedsAreOrderedAroundTheSystemDefault() {
        XCTAssertEqual(Settings.SpeechRate.normal.utteranceRate, 0.5)
        XCTAssertLessThan(Settings.SpeechRate.slow.utteranceRate, 0.5)
        XCTAssertGreaterThan(Settings.SpeechRate.fast.utteranceRate, 0.5)
    }
}

// MARK: - Read aloud

@MainActor
final class ReadAloudTests: XCTestCase {
    private var settings: Settings!
    private var synth: FakeSynthesizer!
    private var escape: EscapeKey!
    private var reader: ReadAloud!

    override func setUp() async throws {
        let name = "ReadAloudTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: name)!)
        synth = FakeSynthesizer()
        escape = EscapeKey()
        reader = ReadAloud(settings: settings, synthesizer: synth, escape: escape)
    }

    func testReadsTheSpeakableTextWithTheChosenVoiceAndSpeed() {
        settings.voiceIdentifier = "voice.a"
        settings.speechRate = .slow
        reader.read("Done.\n\n```\nrm -rf /\n```")
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(synth.spoken[0].text, "Done. See the code below.")
        XCTAssertEqual(synth.spoken[0].voice, "voice.a")
        XCTAssertEqual(synth.spoken[0].rate, Settings.SpeechRate.slow.utteranceRate)
        XCTAssertTrue(reader.isReading("Done.\n\n```\nrm -rf /\n```"))
    }

    func testTheButtonTogglesBetweenReadAndStop() {
        reader.toggle("One.")
        XCTAssertEqual(reader.reading, "One.")
        reader.toggle("One.")
        XCTAssertNil(reader.reading)
        XCTAssertEqual(synth.stops, 1)
    }

    func testStartingAnotherReplyStopsTheCurrentOne() {
        reader.read("One.")
        reader.read("Two.")
        XCTAssertEqual(synth.stops, 1)
        XCTAssertEqual(synth.spoken.map(\.text), ["One.", "Two."])
        // The first utterance's end, reported by the stop, does not end the second.
        XCTAssertEqual(reader.reading, "Two.")
    }

    func testFinishingClearsTheButton() {
        reader.read("One.")
        synth.finishLast()
        XCTAssertNil(reader.reading)
        XCTAssertFalse(escape.isWatching)
    }

    func testEscStopsReading() {
        reader.read("One.")
        XCTAssertTrue(escape.isWatching)
        XCTAssertTrue(escape.press())
        XCTAssertNil(reader.reading)
        XCTAssertEqual(synth.stops, 1)
        XCTAssertFalse(escape.press(), "Esc is not taken when nothing is reading")
    }

    func testAReplyWithNothingToSayStaysSilent() {
        reader.read("---")
        XCTAssertTrue(synth.spoken.isEmpty)
        XCTAssertNil(reader.reading)
    }

    func testOnlyTheMarkedPartIsSpoken() {
        reader.read("Lots of detail.\n\n[TTS]All green.[/TTS]")
        XCTAssertEqual(synth.spoken.last?.text, "All green.")
    }

    func testAReplyIsKnownByItsMessageIdWhileItGrows() {
        reader.read("Working on", key: "m1")
        XCTAssertTrue(reader.isReading("m1"))
        XCTAssertFalse(reader.isReading("Working on"))
        // The same message, more of it streamed in: still the one reading.
        reader.toggle("Working on it. Done.", key: "m1")
        XCTAssertNil(reader.reading)
        // Two replies with the same words are two replies.
        reader.read("Done.", key: "m2")
        XCTAssertFalse(reader.isReading("m3"))
        reader.toggle("Done.", key: "m3")
        XCTAssertTrue(reader.isReading("m3"))
    }

    func testUtteranceTokensMatchTheUtteranceItself() {
        var tokens = UtteranceTokens<NSObject>()
        let first = NSObject()
        let second = NSObject()
        tokens.add(first, token: 1)
        tokens.add(second, token: 2)
        XCTAssertNil(tokens.remove(NSObject()), "another object is not matched")
        XCTAssertEqual(tokens.remove(second), 2)
        XCTAssertNil(tokens.remove(second), "each token once")
        XCTAssertEqual(tokens.remove(first), 1)
        XCTAssertTrue(tokens.isEmpty)
    }
}

// MARK: - Voices

final class VoiceChoicesTests: XCTestCase {
    private let voices: [VoiceOption] = [
        VoiceOption(id: "v.zoe", name: "Zoe", language: "en-US", quality: .premium),
        VoiceOption(id: "v.ava", name: "Ava", language: "en-US"),
        VoiceOption(id: "v.ava2", name: "Ava", language: "en-US", quality: .enhanced),
        VoiceOption(id: "v.thomas", name: "Thomas", language: "fr-FR"),
        VoiceOption(id: "v.bells", name: "Bells", language: "en-US", novelty: true),
        VoiceOption(id: "v.me", name: "Larry", language: "en-US", personal: true),
    ]

    func testTheLanguagesVoicesWithoutNoveltiesBestFirstPerName() {
        let options = VoiceChoices.options(voices, language: "en", personalAllowed: false)
        XCTAssertEqual(options.map(\.id), ["v.ava2", "v.ava", "v.zoe"])
        XCTAssertEqual(options.map(\.label), ["Ava (Enhanced)", "Ava", "Zoe (Premium)"])
    }

    func testPersonalVoiceOnlyWhenAllowedAndFirst() {
        let options = VoiceChoices.options(voices, language: "en-GB", personalAllowed: true)
        XCTAssertEqual(options.first?.id, "v.me")
        XCTAssertEqual(options.first?.label, "Larry (Personal Voice)")
    }
}

// MARK: - Talk

@MainActor
final class DictationTests: XCTestCase {
    private var settings: Settings!
    private var transcriber: FakeTranscriber!
    private var permissions: FakePermissions!
    private var escape: EscapeKey!

    override func setUp() async throws {
        settings = Settings(defaults: UserDefaults(suiteName: "DictationTests-\(UUID().uuidString)")!)
        transcriber = FakeTranscriber()
        permissions = FakePermissions()
        escape = EscapeKey()
    }

    private func dictation(info: @escaping (String) -> Any? = bundled, available: Bool = true) -> Dictation {
        let transcriber = self.transcriber!
        return Dictation(
            settings: settings, transcriber: { available ? transcriber : nil }, permissions: permissions,
            info: info, escape: escape)
    }

    // MARK: the guard

    func testTheGuardWantsBothUsageStrings() {
        XCTAssertNil(VoiceInputGuard.problem(info: bundled))
        XCTAssertEqual(VoiceInputGuard.problem(info: { _ in nil }), VoiceInputGuard.needsInstalledApp)
        XCTAssertEqual(
            VoiceInputGuard.problem(info: { $0 == "NSMicrophoneUsageDescription" ? "why" : nil }),
            VoiceInputGuard.needsInstalledApp)
        XCTAssertEqual(VoiceInputGuard.problem(info: { _ in "" }), VoiceInputGuard.needsInstalledApp)
    }

    func testWithoutAnInfoPlistNothingIsAskedOrStarted() async {
        let talk = dictation(info: { _ in nil })
        let box = FakeComposer()
        await talk.toggle(box.composer)
        XCTAssertEqual(talk.notice, VoiceInputGuard.needsInstalledApp)
        XCTAssertTrue(permissions.asked.isEmpty)
        XCTAssertEqual(transcriber.starts, 0)
        XCTAssertEqual(talk.phase, .idle)
    }

    // MARK: permissions

    func testPermissionsAreAskedOnTheFirstPressOnly() async {
        let talk = dictation()
        let box = FakeComposer()
        XCTAssertTrue(permissions.asked.isEmpty, "nothing is asked before the mic is pressed")
        await talk.toggle(box.composer)
        XCTAssertEqual(permissions.asked, ["microphone", "speech"])
        await talk.toggle(box.composer)
        await talk.toggle(box.composer)
        XCTAssertEqual(permissions.asked, ["microphone", "speech"])
        XCTAssertEqual(transcriber.starts, 2)
    }

    func testARefusedMicrophoneSaysWhereToTurnItOn() async {
        permissions.grantMicrophone = false
        let talk = dictation()
        await talk.toggle(FakeComposer().composer)
        XCTAssertEqual(talk.notice, Dictation.microphoneOff)
        XCTAssertEqual(permissions.asked, ["microphone"])
        XCTAssertEqual(transcriber.starts, 0)

        permissions.speech = .denied
        permissions.microphone = .granted
        await talk.toggle(FakeComposer().composer)
        XCTAssertEqual(talk.notice, Dictation.speechOff)
    }

    func testBeforeMacOS26ItSaysSo() async {
        permissions.microphone = .granted
        permissions.speech = .granted
        let talk = dictation(available: false)
        await talk.toggle(FakeComposer().composer)
        XCTAssertEqual(talk.notice, "Voice input needs macOS 26 or later.")
    }

    func testAStartThatFailsShowsWhyAndGoesBackToIdle() async {
        transcriber.startError = TalkError(message: "Voice input does not support this Mac's language yet.")
        let talk = dictation()
        await talk.toggle(FakeComposer().composer)
        XCTAssertEqual(talk.notice, "Voice input does not support this Mac's language yet.")
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertNil(talk.target)
    }

    // MARK: words into the composer

    func testWordsLandAfterWhatWasTypedAsTheyAreRecognised() async {
        let talk = dictation()
        let box = FakeComposer(text: "Please")
        await talk.toggle(box.composer)
        XCTAssertEqual(talk.phase, .listening)
        XCTAssertEqual(talk.target, "chat-1")
        XCTAssertEqual(DictationLine.text(talk, composer: "chat-1"), Dictation.listeningLine)
        XCTAssertNil(DictationLine.text(talk, composer: "start"))

        transcriber.update?(Transcript(finalized: "", volatile: "fix the"))
        XCTAssertEqual(box.text, "Please fix the")
        transcriber.update?(Transcript(finalized: "fix the build.", volatile: ""))
        transcriber.update?(Transcript(finalized: "fix the build.", volatile: "Thanks"))
        XCTAssertEqual(box.text, "Please fix the build. Thanks")
        transcriber.level?(0.7)
        XCTAssertEqual(talk.level, 0.7)

        await talk.toggle(box.composer)
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(talk.level, 0)
        XCTAssertEqual(box.text, "Please fix the build. Thanks", "stopping leaves the words to glance at")
        XCTAssertTrue(box.sends.isEmpty, "Send when I stop talking is off by default")
    }

    func testSendWhenIStopTalking() async {
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer()
        await talk.toggle(box.composer)
        transcriber.update?(Transcript(finalized: "Ship it.", volatile: ""))
        await talk.toggle(box.composer)
        XCTAssertEqual(box.sends, ["Ship it."])
    }

    func testNothingHeardSendsNothing() async {
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer()
        await talk.toggle(box.composer)
        await talk.toggle(box.composer)
        XCTAssertTrue(box.sends.isEmpty)
    }

    func testEscStopsWithoutSending() async {
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer()
        await talk.toggle(box.composer)
        transcriber.update?(Transcript(finalized: "Draft only", volatile: ""))
        XCTAssertTrue(escape.press())
        // The stop runs in a task: let it.
        for _ in 0..<20 where talk.phase != .idle { await Task.yield() }
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertEqual(box.text, "Draft only")
        XCTAssertTrue(box.sends.isEmpty)
    }

    func testTheMicInAnotherComposerMovesTheTalkThere() async {
        let talk = dictation()
        let first = FakeComposer("chat-1")
        let second = FakeComposer("start")
        await talk.toggle(first.composer)
        await talk.toggle(second.composer)
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertEqual(talk.target, "start")
        transcriber.update?(Transcript(finalized: "here", volatile: ""))
        XCTAssertEqual(second.text, "here")
        XCTAssertEqual(first.text, "")
    }

    func testTheTranscriberFailingMidwayStopsAndSaysWhy() async {
        let talk = dictation()
        await talk.toggle(FakeComposer().composer)
        transcriber.failed?("Voice input stopped: the microphone went away.")
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(talk.notice, "Voice input stopped: the microphone went away.")
        XCTAssertFalse(escape.isWatching)
        XCTAssertEqual(transcriber.stops, 1, "the microphone is let go after a failure too")
    }

    // MARK: hold-to-talk

    func testHoldToTalkIsOffByDefault() async {
        let talk = dictation()
        let box = FakeComposer()
        talk.shown(box.composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: rightOptionDown)
        await talk.holdDelayElapsed()
        XCTAssertEqual(transcriber.starts, 0)
    }

    func testHoldingRightOptionTalksIntoTheShownComposerAndReleaseStops() async {
        settings.holdToTalk = .rightOption
        let talk = dictation()
        let box = FakeComposer("start")
        talk.shown(box.composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: rightOptionDown)
        await talk.holdDelayElapsed()
        XCTAssertEqual(talk.target, "start")
        XCTAssertTrue(talk.byHold)
        XCTAssertEqual(DictationLine.text(talk, composer: "start"), Dictation.holdingLine)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: 0)
        for _ in 0..<20 where talk.phase != .idle { await Task.yield() }
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertEqual(talk.phase, .idle)
    }

    func testTheKeyIgnoredWhenVoiceInputIsOff() async {
        settings.holdToTalk = .rightOption
        settings.voiceInputEnabled = false
        let talk = dictation()
        talk.shown(FakeComposer().composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: rightOptionDown)
        await talk.holdDelayElapsed()
        XCTAssertEqual(transcriber.starts, 0)
    }

    func testRightOptionReleasedWhileLeftOptionIsHeldEndsTheHold() async {
        settings.holdToTalk = .rightOption
        let talk = dictation()
        talk.shown(FakeComposer().composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: rightOptionDown | 0x20)
        await talk.holdDelayElapsed()
        XCTAssertEqual(talk.phase, .listening)
        // Right Option up, Left Option still down: `.option` is still set.
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: leftOptionDown)
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(transcriber.stops, 1)
    }

    func testAKeyTypedDuringTheHoldCancelsWithoutSendingAndRestoresTheText() async {
        settings.holdToTalk = .rightOption
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer(text: "Hi")
        talk.shown(box.composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: rightOptionDown)
        await talk.holdDelayElapsed()
        transcriber.update?(Transcript(finalized: "", volatile: "there"))
        XCTAssertEqual(box.text, "Hi there")
        talk.keyDown()  // Option+E, for an accent
        XCTAssertEqual(box.text, "Hi", "what the composer held before the talk")
        transcriber.update?(Transcript(finalized: "there", volatile: ""))
        XCTAssertEqual(box.text, "Hi")
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: 0)
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertTrue(box.sends.isEmpty)
    }

    func testReleasingTheKeyDuringThePermissionPromptEndsTheTalk() async {
        settings.holdToTalk = .rightOption
        permissions.promptStaysUp = true
        let talk = dictation()
        talk.shown(FakeComposer().composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: rightOptionDown)
        let starting = Task { await talk.holdDelayElapsed() }
        await settle { permissions.isPromptUp }
        XCTAssertEqual(talk.phase, .starting)
        XCTAssertTrue(talk.byHold)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: 0)
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle)
        permissions.answer()
        await starting.value
        XCTAssertEqual(transcriber.starts, 0, "the key was up before the prompt was answered")
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertNil(talk.target)
    }

    // MARK: one talk, in a composer it owns

    func testSendingWhileListeningEndsTheTalkAndNothingRefillsOrSendsAgain() async {
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer()
        await talk.toggle(box.composer)
        transcriber.update?(Transcript(finalized: "Ship it.", volatile: ""))
        // Send, as the composer does: Talk first, then the draft goes and clears.
        talk.willSend(from: "chat-1")
        box.sends.append(box.text)
        box.text = ""
        transcriber.update?(Transcript(finalized: "Ship it.", volatile: "and"))
        transcriber.update?(Transcript(finalized: "Ship it. And more.", volatile: ""))
        XCTAssertEqual(box.text, "", "the sent text is not written back")
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertEqual(box.sends, ["Ship it."], "sent once, by the person")
    }

    func testAClearedDraftIsNotRefilled() async {
        let talk = dictation()
        let box = FakeComposer()
        await talk.toggle(box.composer)
        transcriber.update?(Transcript(finalized: "", volatile: "hello"))
        box.text = ""
        transcriber.update?(Transcript(finalized: "hello there", volatile: ""))
        XCTAssertEqual(box.text, "")
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle)
    }

    func testHandEditsWhileListeningAreNeverOverwritten() async {
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer(text: "Please")
        await talk.toggle(box.composer)
        transcriber.update?(Transcript(finalized: "", volatile: "fix the"))
        XCTAssertEqual(box.text, "Please fix the")
        box.text = "Please fix the bug"  // typed while listening
        transcriber.update?(Transcript(finalized: "fix the build.", volatile: ""))
        XCTAssertEqual(box.text, "Please fix the bug")
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle, "Talk lets go of the composer")
        XCTAssertTrue(box.sends.isEmpty)
    }

    func testAComposerGoingAwayEndsItsTalkUnsent() async {
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer()
        talk.shown(box.composer)
        await talk.toggle(box.composer)
        transcriber.update?(Transcript(finalized: "Half a thought", volatile: ""))
        talk.hidden("chat-1")
        transcriber.update?(Transcript(finalized: "Half a thought, finished", volatile: ""))
        XCTAssertEqual(box.text, "Half a thought", "nothing written into a composer no one sees")
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertTrue(box.sends.isEmpty)
        XCTAssertFalse(escape.isWatching)
    }

    func testAComposerMadeAgainForTheSameChatKeepsItsTalk() async {
        settings.holdToTalk = .rightOption
        let talk = dictation()
        let box = FakeComposer()
        let old = UUID()
        let new = UUID()
        talk.shown(box.composer.shown(by: old))
        // The new view appears before the old one goes.
        talk.shown(box.composer.shown(by: new))
        await talk.toggle(box.composer.shown(by: new))
        talk.hidden("chat-1", instance: old)
        await settle { talk.phase == .idle }
        XCTAssertEqual(talk.phase, .listening, "the old view going does not end the new one's talk")
        transcriber.update?(Transcript(finalized: "still here", volatile: ""))
        XCTAssertEqual(box.text, "still here")
        await talk.toggle(box.composer.shown(by: new))
        // Hold-to-talk still has the new view to fill.
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, flags: rightOptionDown)
        await talk.holdDelayElapsed()
        XCTAssertEqual(talk.target, "chat-1")
        XCTAssertEqual(talk.phase, .listening)
    }

    func testClosingTheWindowOrQuittingEndsTheTalkUnsent() async {
        settings.sendWhenStopTalking = true
        let talk = dictation()
        let box = FakeComposer()
        await talk.toggle(box.composer)
        transcriber.update?(Transcript(finalized: "Unsent", volatile: ""))
        await talk.cancel()
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertTrue(box.sends.isEmpty)
    }

    func testASecondPressWhileAskingStopsAndNothingStarts() async {
        permissions.promptStaysUp = true
        let talk = dictation()
        let box = FakeComposer()
        let first = Task { await talk.toggle(box.composer) }
        await settle { permissions.isPromptUp }
        XCTAssertEqual(talk.phase, .starting, "the talk is the composer's from the press")
        await talk.toggle(box.composer)
        XCTAssertEqual(talk.phase, .idle)
        permissions.answer()
        await first.value
        XCTAssertEqual(transcriber.starts, 0)
        XCTAssertEqual(talk.phase, .idle)
    }

    func testAStartWhileTheLastTalkIsFinishingIsRefused() async {
        let talk = dictation()
        let first = FakeComposer("chat-1")
        let second = FakeComposer("start")
        await talk.toggle(first.composer)
        transcriber.holdStops = true
        let stopping = Task { await talk.stop(sending: false) }
        await settle { talk.phase == .finishing }
        XCTAssertEqual(talk.phase, .finishing)
        await talk.toggle(second.composer)
        XCTAssertEqual(transcriber.starts, 1, "one transcriber at a time")
        XCTAssertEqual(talk.target, "chat-1")
        transcriber.resumeStops()
        await stopping.value
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertNil(talk.target)
    }

    func testAnOldTalkEndingLateLeavesTheNewOneAlone() async {
        let talk = dictation()
        let first = FakeComposer("chat-1")
        let second = FakeComposer("start")
        transcriber.suspendNextStart = true
        let starting = Task { await talk.toggle(first.composer) }
        await settle { transcriber.isStartSuspended }
        let oldUpdate = transcriber.update
        let oldFailed = transcriber.failed
        // Pressed again while starting, then the welcome's mic.
        await talk.toggle(first.composer)
        XCTAssertEqual(talk.phase, .idle)
        await talk.toggle(second.composer)
        XCTAssertEqual(talk.phase, .listening)
        transcriber.resumeStart()
        await starting.value
        XCTAssertEqual(talk.phase, .listening)
        XCTAssertEqual(talk.target, "start")
        XCTAssertEqual(transcriber.stops, 1, "the old transcriber was stopped once")
        oldUpdate?(Transcript(finalized: "late words", volatile: ""))
        oldFailed?("Voice input stopped: old news.")
        XCTAssertEqual(first.text, "")
        XCTAssertNil(talk.notice)
        XCTAssertEqual(talk.phase, .listening)
        transcriber.update?(Transcript(finalized: "new words", volatile: ""))
        XCTAssertEqual(second.text, "new words")
    }

    // MARK: the time limit on finishing

    func testDeadlineSaysWhetherWorkFinishedInTime() async {
        let quick = await Deadline.run(within: .seconds(5)) {}
        XCTAssertTrue(quick)
        let failing = await Deadline.run(within: .seconds(5)) { throw TalkError(message: "no") }
        XCTAssertFalse(failing)
        let clock = ContinuousClock()
        let began = clock.now
        let hung = await Deadline.run(within: .milliseconds(50)) { try await Task.sleep(for: .seconds(30)) }
        XCTAssertFalse(hung)
        XCTAssertLessThan(clock.now - began, .seconds(5), "a hung finish is not waited for")
    }
}

// MARK: - Pure parts of Talk

final class DictationTextTests: XCTestCase {
    func testPrefix() {
        XCTAssertEqual(DictationText.prefix(for: ""), "")
        XCTAssertEqual(DictationText.prefix(for: "Hi"), "Hi ")
        XCTAssertEqual(DictationText.prefix(for: "Hi\n"), "Hi\n")
        XCTAssertEqual(DictationText.prefix(for: "Hi "), "Hi ")
    }

    func testSegmentsJoinWithOneSpaceAndNoneBeforePunctuation() {
        XCTAssertEqual(DictationText.joined(["fix the", "build"]), "fix the build")
        XCTAssertEqual(DictationText.joined(["fix the ", "build"]), "fix the build")
        XCTAssertEqual(DictationText.joined(["done", "."]), "done.")
        XCTAssertEqual(DictationText.joined(["", " hello", ""]), "hello")
        XCTAssertEqual(Transcript(finalized: "One.", volatile: "Two").text, "One. Two")
    }

    func testTheMeterScale() {
        XCTAssertEqual(VoiceLevel.normalised(rms: 0), 0)
        XCTAssertEqual(VoiceLevel.normalised(rms: 1), 1)
        XCTAssertEqual(VoiceLevel.normalised(rms: 0.001), 0)
        XCTAssertEqual(VoiceLevel.normalised(rms: pow(10, -25.0 / 20)), 0.5, accuracy: 0.001)
    }
}

final class HoldToTalkTrackerTests: XCTestCase {
    private let key = HoldToTalkTracker.rightOptionKeyCode

    func testHeldAloneBeginsAndReleaseEnds() {
        var tracker = HoldToTalkTracker()
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: rightOptionDown, shortcut: .rightOption), .arm)
        XCTAssertEqual(tracker.delayElapsed(), .begin)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: 0, shortcut: .rightOption), .end)
        XCTAssertEqual(tracker.state, .idle)
    }

    func testATapIsNotATalk() {
        var tracker = HoldToTalkTracker()
        _ = tracker.flagsChanged(keyCode: key, flags: rightOptionDown, shortcut: .rightOption)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: 0, shortcut: .rightOption), .none)
        XCTAssertEqual(tracker.delayElapsed(), .none)
    }

    func testOptionAsAModifierIsNotATalk() {
        var tracker = HoldToTalkTracker()
        _ = tracker.flagsChanged(keyCode: key, flags: rightOptionDown, shortcut: .rightOption)
        tracker.keyDown()
        XCTAssertEqual(tracker.delayElapsed(), .none)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: 0, shortcut: .rightOption), .none)
    }

    func testRightOptionUpWhileLeftOptionIsHeldEnds() {
        var tracker = HoldToTalkTracker()
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: rightOptionDown | 0x20, shortcut: .rightOption), .arm)
        XCTAssertEqual(tracker.delayElapsed(), .begin)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: leftOptionDown, shortcut: .rightOption), .end)
        XCTAssertEqual(tracker.state, .idle)
    }

    func testAKeyTypedWhileListeningCancels() {
        var tracker = HoldToTalkTracker()
        _ = tracker.flagsChanged(keyCode: key, flags: rightOptionDown, shortcut: .rightOption)
        XCTAssertEqual(tracker.delayElapsed(), .begin)
        XCTAssertEqual(tracker.keyDown(), .cancel)
        XCTAssertEqual(tracker.keyDown(), .none, "cancelled once")
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: 0, shortcut: .rightOption), .none)
    }

    func testOtherKeysAndNoShortcutAreIgnored() {
        var tracker = HoldToTalkTracker()
        XCTAssertEqual(tracker.flagsChanged(keyCode: 58, flags: rightOptionDown, shortcut: .rightOption), .none)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, flags: rightOptionDown, shortcut: .none), .none)
        XCTAssertEqual(tracker.state, .idle)
    }
}
