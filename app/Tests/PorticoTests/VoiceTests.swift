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
    }

    func stop() async { stops += 1 }
}

@MainActor
private final class FakePermissions: VoicePermissions {
    var microphone: VoicePermission = .notAsked
    var speech: VoicePermission = .notAsked
    var grantMicrophone = true
    var grantSpeech = true
    private(set) var asked: [String] = []

    func requestMicrophone() async -> Bool {
        asked.append("microphone")
        microphone = grantMicrophone ? .granted : .denied
        return grantMicrophone
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
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(talk.notice, "Voice input stopped: the microphone went away.")
        XCTAssertFalse(escape.isWatching)
    }

    // MARK: hold-to-talk

    func testHoldToTalkIsOffByDefault() async {
        let talk = dictation()
        let box = FakeComposer()
        talk.shown(box.composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, down: true)
        await talk.holdDelayElapsed()
        XCTAssertEqual(transcriber.starts, 0)
    }

    func testHoldingRightOptionTalksIntoTheShownComposerAndReleaseStops() async {
        settings.holdToTalk = .rightOption
        let talk = dictation()
        let box = FakeComposer("start")
        talk.shown(box.composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, down: true)
        await talk.holdDelayElapsed()
        XCTAssertEqual(talk.target, "start")
        XCTAssertTrue(talk.byHold)
        XCTAssertEqual(DictationLine.text(talk, composer: "start"), Dictation.holdingLine)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, down: false)
        for _ in 0..<20 where talk.phase != .idle { await Task.yield() }
        XCTAssertEqual(transcriber.stops, 1)
        XCTAssertEqual(talk.phase, .idle)
    }

    func testTheKeyIgnoredWhenVoiceInputIsOff() async {
        settings.holdToTalk = .rightOption
        settings.voiceInputEnabled = false
        let talk = dictation()
        talk.shown(FakeComposer().composer)
        talk.flagsChanged(keyCode: HoldToTalkTracker.rightOptionKeyCode, down: true)
        await talk.holdDelayElapsed()
        XCTAssertEqual(transcriber.starts, 0)
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
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, down: true, shortcut: .rightOption), .arm)
        XCTAssertEqual(tracker.delayElapsed(), .begin)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, down: false, shortcut: .rightOption), .end)
        XCTAssertEqual(tracker.state, .idle)
    }

    func testATapIsNotATalk() {
        var tracker = HoldToTalkTracker()
        _ = tracker.flagsChanged(keyCode: key, down: true, shortcut: .rightOption)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, down: false, shortcut: .rightOption), .none)
        XCTAssertEqual(tracker.delayElapsed(), .none)
    }

    func testOptionAsAModifierIsNotATalk() {
        var tracker = HoldToTalkTracker()
        _ = tracker.flagsChanged(keyCode: key, down: true, shortcut: .rightOption)
        tracker.keyDown()
        XCTAssertEqual(tracker.delayElapsed(), .none)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, down: false, shortcut: .rightOption), .none)
    }

    func testOtherKeysAndNoShortcutAreIgnored() {
        var tracker = HoldToTalkTracker()
        XCTAssertEqual(tracker.flagsChanged(keyCode: 58, down: true, shortcut: .rightOption), .none)
        XCTAssertEqual(tracker.flagsChanged(keyCode: key, down: true, shortcut: .none), .none)
        XCTAssertEqual(tracker.state, .idle)
    }
}
