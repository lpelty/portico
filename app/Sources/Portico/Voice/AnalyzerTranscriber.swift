import AVFoundation
import Foundation
import Speech

/// The transcriber Talk uses on this Mac, or nil before macOS 26.
enum OnDeviceTranscription {
    @MainActor
    static func make() -> SpeechTranscribing? {
        if #available(macOS 26, *) { return AnalyzerTranscriber() }
        return nil
    }
}

/// On-device transcription with the Speech framework's `SpeechAnalyzer`
/// (v0.9 decision 1, macOS 26): `SpeechTranscriber` where the Mac supports
/// it, else `DictationTranscriber`, the same on-device model the system's
/// dictation uses. The microphone is read with `AVAudioEngine` and its
/// buffers converted to the analyzer's format. Nothing is sent anywhere:
/// the only download is the system's own speech model for the language,
/// the first time, through `AssetInventory`.
@available(macOS 26, *)
@MainActor
final class AnalyzerTranscriber: SpeechTranscribing {
    private let audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    /// The microphone is running (its tap installed).
    private var running = false
    /// `stop` came; a start still on its way gives up at its next step.
    private var stopped = false
    /// The results stream failed; a start still on its way gives up too.
    private var resultsFailed = false

    /// How long the last words may take to finalise before they are dropped.
    static let finishLimit: Duration = .seconds(3)

    func start(
        update: @escaping @MainActor (Transcript) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) async throws {
        let node = audio.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw Self.noMicrophone }
        let failed: @MainActor (String) -> Void = { [weak self] message in
            self?.resultsFailed = true
            failed(message)
        }

        // SpeechTranscriber where it takes the language, else DictationTranscriber.
        let module: any SpeechModule
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            module = transcriber
            results = Self.consume(transcriber.results, text: { $0.text }, update: update, failed: failed)
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) {
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            module = transcriber
            results = Self.consume(transcriber.results, text: { $0.text }, update: update, failed: failed)
        } else {
            throw Self.unsupportedLanguage
        }

        do {
            try await prepare(module)
            guard !stopped, !resultsFailed else { return await tearDown() }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw TalkError(message: "Voice input could not find an audio format the speech model takes.")
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            input = continuation
            let feed = try AudioFeed(from: micFormat, to: format, input: continuation) { value in
                Task { @MainActor in level(value) }
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            self.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
            guard !stopped, !resultsFailed else { return await tearDown() }

            node.installTap(onBus: 0, bufferSize: 4096, format: micFormat, block: Self.tap(feed))
            running = true
            audio.prepare()
            do {
                try audio.start()
            } catch {
                throw TalkError(message: "The microphone could not start: \(error.localizedDescription)")
            }
        } catch {
            await tearDown()
            throw error
        }
    }

    func stop() async {
        stopped = true
        guard running else { return }
        running = false
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        input?.finish()
        guard let analyzer else { return }
        // The last words, unless finalising fails or hangs: then they go.
        let results = self.results
        let finished = await Deadline.run(within: Self.finishLimit) {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await results?.value
        }
        if !finished {
            await analyzer.cancelAndFinishNow()
            results?.cancel()
        }
    }

    /// Undoes a start that did not get to listening: the tap, the engine,
    /// the analyzer and the results.
    private func tearDown() async {
        if running {
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
            running = false
        }
        input?.finish()
        input = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        results?.cancel()
    }

    private static let unsupportedLanguage = TalkError(
        message: "Voice input does not support this Mac's language yet.")
    static let noMicrophone = TalkError(message: "No microphone is available.")

    /// The language's speech model, installed the first time.
    private func prepare(_ module: any SpeechModule) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return
        case .unsupported:
            throw Self.unsupportedLanguage
        default:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
    }

    /// The tap's block, made outside the main actor: the audio thread calls it.
    private nonisolated static func tap(_ feed: AudioFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.push(buffer) }
    }

    /// Reads a module's results into transcripts: a final result joins the
    /// finalised text, a volatile one replaces the part still changing.
    private static func consume<Results: AsyncSequence & Sendable>(
        _ results: Results,
        text: @escaping @Sendable (Results.Element) -> AttributedString,
        update: @escaping @MainActor (Transcript) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never> where Results.Element: SpeechModuleResult & Sendable {
        Task { @MainActor in
            var transcript = Transcript()
            do {
                for try await result in results {
                    let words = String(text(result).characters)
                    if result.isFinal {
                        transcript.finalized = DictationText.joined([transcript.finalized, words])
                        transcript.volatile = ""
                    } else {
                        transcript.volatile = words
                    }
                    update(transcript)
                }
            } catch is CancellationError {
            } catch {
                failed("Voice input stopped: \(error.localizedDescription)")
            }
        }
    }
}

/// Microphone buffers into the analyzer's format, with the input level.
/// Used from the audio thread only, after it is made.
@available(macOS 26, *)
private final class AudioFeed: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let level: @Sendable (Float) -> Void

    init(
        from source: AVAudioFormat, to target: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation, level: @escaping @Sendable (Float) -> Void
    ) throws {
        if source == target {
            self.converter = nil
        } else {
            // Unconverted buffers would be the wrong format for the analyzer.
            guard let converter = AVAudioConverter(from: source, to: target) else {
                throw TalkError(message: "Voice input could not read this microphone's audio format.")
            }
            self.converter = converter
        }
        self.target = target
        self.input = input
        self.level = level
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        level(Self.level(of: buffer))
        guard let converter else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let once = OneBuffer(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard let next = once.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        if error == nil, out.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: out))
        }
    }

    /// The buffer's loudness, 0–1: its RMS in decibels, -50 dB to 0.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return VoiceLevel.normalised(rms: rms)
    }
}

/// One buffer handed to the converter once; the converter asks again
/// within the same call, on the same thread.
private final class OneBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Work raced against a time limit: true when it finished, without
/// throwing, in time. The work is not waited for past the limit.
enum Deadline {
    static func run(within limit: Duration, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            Task {
                let done: Void? = try? await work()
                once.resume(done != nil)
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(false)
            }
        }
    }
}

/// A continuation resumed by whichever of two tasks comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Bool) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

/// The meter's scale. Pure, so it is tested.
enum VoiceLevel {
    static let floorDecibels: Float = -50

    static func normalised(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}

/// The microphone and speech recognition permissions, from the system.
@MainActor
struct SystemVoicePermissions: VoicePermissions {
    var microphone: VoicePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    var speech: VoicePermission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
