import Foundation

/// The keys a recording notes; an enum so no free text can enter a recording.
enum ScrollKey: String, Codable, Sendable { case pageUp, pageDown, home, end, up, down, space }

/// SwiftUI's scroll phase names, as an enum for the same reason.
enum ScrollPhaseName: String, Codable, Sendable { case idle, tracking, interacting, decelerating, animating }

/// v0.26.4: one line of a conversation recording. Nothing here is content: ids,
/// counts, sizes and flags only (D4). Each line is one JSON object with a `kind`
/// (the case name), `t` (ms since the recording began) and the case's fields.
enum RecordingEvent: Codable, Equatable, Sendable {
    case open(chat: Int, appVersion: String, macOS: String, window: [Int], column: Int, viewerVisible: Bool, viewerWidth: Int, sidebarVisible: Bool, textScale: Double)
    case shape(EntryShape)
    case removed(id: String)
    case imageLoaded(id: String, index: Int, height: Int)
    case window(width: Int, height: Int)
    case column(width: Int)
    case viewer(visible: Bool, width: Int, shown: String?)
    case sidebar(visible: Bool)
    case textScale(Double)
    case wheel(deltaY: Double, precise: Bool, phase: Int, momentum: Int)
    case key(ScrollKey)
    case jump(id: String)
    case phase(ScrollPhaseName)
    case delta(turn: Int, chars: Int)
    case turnFinished(turn: Int)
    case toolRow(id: String)
    case card(id: String, docked: Bool)
    case capped(bytes: Int)

    private enum Key: String, CodingKey {
        case kind, value
        case chat, appVersion, macOS, window, column, viewerVisible, viewerWidth, sidebarVisible, textScale
        case id, index, height, width, visible, shown, deltaY, precise, phase, momentum
        case turn, chars, docked, bytes
    }

    private var kindName: String {
        switch self {
        case .open: "open"
        case .shape: "shape"
        case .removed: "removed"
        case .imageLoaded: "imageLoaded"
        case .window: "window"
        case .column: "column"
        case .viewer: "viewer"
        case .sidebar: "sidebar"
        case .textScale: "textScale"
        case .wheel: "wheel"
        case .key: "key"
        case .jump: "jump"
        case .phase: "phase"
        case .delta: "delta"
        case .turnFinished: "turnFinished"
        case .toolRow: "toolRow"
        case .card: "card"
        case .capped: "capped"
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kindName, forKey: .kind)
        switch self {
        case let .open(chat, appVersion, macOS, window, column, viewerVisible, viewerWidth, sidebarVisible, textScale):
            try c.encode(chat, forKey: .chat); try c.encode(appVersion, forKey: .appVersion); try c.encode(macOS, forKey: .macOS)
            try c.encode(window, forKey: .window); try c.encode(column, forKey: .column)
            try c.encode(viewerVisible, forKey: .viewerVisible); try c.encode(viewerWidth, forKey: .viewerWidth)
            try c.encode(sidebarVisible, forKey: .sidebarVisible); try c.encode(textScale, forKey: .textScale)
        case .shape(let s): try c.encode(s, forKey: .value)
        case .removed(let id), .jump(let id), .toolRow(let id): try c.encode(id, forKey: .id)
        case let .imageLoaded(id, index, height):
            try c.encode(id, forKey: .id); try c.encode(index, forKey: .index); try c.encode(height, forKey: .height)
        case let .window(width, height): try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
        case .column(let width): try c.encode(width, forKey: .width)
        case let .viewer(visible, width, shown):
            try c.encode(visible, forKey: .visible); try c.encode(width, forKey: .width); try c.encodeIfPresent(shown, forKey: .shown)
        case .sidebar(let visible): try c.encode(visible, forKey: .visible)
        case .textScale(let v): try c.encode(v, forKey: .value)
        case let .wheel(deltaY, precise, phase, momentum):
            try c.encode(deltaY, forKey: .deltaY); try c.encode(precise, forKey: .precise)
            try c.encode(phase, forKey: .phase); try c.encode(momentum, forKey: .momentum)
        case .key(let v): try c.encode(v, forKey: .value)
        case .phase(let v): try c.encode(v, forKey: .value)
        case let .delta(turn, chars): try c.encode(turn, forKey: .turn); try c.encode(chars, forKey: .chars)
        case .turnFinished(let turn): try c.encode(turn, forKey: .turn)
        case let .card(id, docked): try c.encode(id, forKey: .id); try c.encode(docked, forKey: .docked)
        case .capped(let bytes): try c.encode(bytes, forKey: .bytes)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "open":
            self = .open(
                chat: try c.decode(Int.self, forKey: .chat), appVersion: try c.decode(String.self, forKey: .appVersion),
                macOS: try c.decode(String.self, forKey: .macOS), window: try c.decode([Int].self, forKey: .window),
                column: try c.decode(Int.self, forKey: .column), viewerVisible: try c.decode(Bool.self, forKey: .viewerVisible),
                viewerWidth: try c.decode(Int.self, forKey: .viewerWidth), sidebarVisible: try c.decode(Bool.self, forKey: .sidebarVisible),
                textScale: try c.decode(Double.self, forKey: .textScale))
        case "shape": self = .shape(try c.decode(EntryShape.self, forKey: .value))
        case "removed": self = .removed(id: try c.decode(String.self, forKey: .id))
        case "imageLoaded":
            self = .imageLoaded(id: try c.decode(String.self, forKey: .id), index: try c.decode(Int.self, forKey: .index), height: try c.decode(Int.self, forKey: .height))
        case "window": self = .window(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height))
        case "column": self = .column(width: try c.decode(Int.self, forKey: .width))
        case "viewer":
            self = .viewer(visible: try c.decode(Bool.self, forKey: .visible), width: try c.decode(Int.self, forKey: .width), shown: try c.decodeIfPresent(String.self, forKey: .shown))
        case "sidebar": self = .sidebar(visible: try c.decode(Bool.self, forKey: .visible))
        case "textScale": self = .textScale(try c.decode(Double.self, forKey: .value))
        case "wheel":
            self = .wheel(deltaY: try c.decode(Double.self, forKey: .deltaY), precise: try c.decode(Bool.self, forKey: .precise),
                          phase: try c.decode(Int.self, forKey: .phase), momentum: try c.decode(Int.self, forKey: .momentum))
        case "key": self = .key(try c.decode(ScrollKey.self, forKey: .value))
        case "jump": self = .jump(id: try c.decode(String.self, forKey: .id))
        case "phase": self = .phase(try c.decode(ScrollPhaseName.self, forKey: .value))
        case "delta": self = .delta(turn: try c.decode(Int.self, forKey: .turn), chars: try c.decode(Int.self, forKey: .chars))
        case "turnFinished": self = .turnFinished(turn: try c.decode(Int.self, forKey: .turn))
        case "toolRow": self = .toolRow(id: try c.decode(String.self, forKey: .id))
        case "card": self = .card(id: try c.decode(String.self, forKey: .id), docked: try c.decode(Bool.self, forKey: .docked))
        case "capped": self = .capped(bytes: try c.decode(Int.self, forKey: .bytes))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown recording kind \(kind)")
        }
    }
}

/// One JSON line: the event plus its time.
private struct RecordingLine: Codable {
    var t: Int
    var event: RecordingEvent

    private enum TimeKey: String, CodingKey { case t }

    init(t: Int, event: RecordingEvent) { self.t = t; self.event = event }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TimeKey.self)
        try c.encode(t, forKey: .t)
        try event.encode(to: encoder)
    }

    init(from decoder: Decoder) throws {
        t = try decoder.container(keyedBy: TimeKey.self).decode(Int.self, forKey: .t)
        event = try RecordingEvent(from: decoder)
    }
}

/// Owns the file and the byte buffer; touched only on the recorder's queue.
private final class RecordingWriter: @unchecked Sendable {
    private let cap: Int
    private let encoder = JSONEncoder()
    private var handle: FileHandle?
    private var buffer = Data()
    private var written = 0
    private var finished = false

    init(handle: FileHandle?, cap: Int) {
        self.handle = handle
        self.cap = cap
        finished = handle == nil
    }

    /// Creates `recordings/` (0700) only when its parent `diagnostics/` exists, then the file
    /// (0600, exclusive: a name already taken gets `-2`, `-3`, ...). Returns the URL used and
    /// the handle, or `nil` when nothing may be created.
    static func create(directory: URL, stem: String) -> (url: URL, handle: FileHandle?) {
        let fm = FileManager.default
        let nominal = directory.appendingPathComponent("\(stem).jsonl")
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: directory.path, isDirectory: &isDir) {
            guard fm.fileExists(atPath: directory.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else {
                return (nominal, nil)
            }
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch { return (nominal, nil) }
        }
        for n in 1...1000 {
            let url = n == 1 ? nominal : directory.appendingPathComponent("\(stem)-\(n).jsonl")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 { return (url, FileHandle(fileDescriptor: fd, closeOnDealloc: true)) }
            if errno != EEXIST { break }
        }
        return (nominal, nil)
    }

    func append(t: Int, event: RecordingEvent) {
        guard !finished, handle != nil, let line = line(t: t, event: event) else { return }
        buffer.append(line)
        let total = written + buffer.count
        if total >= cap {
            if let end = self.line(t: t, event: .capped(bytes: total)) { buffer.append(end) }
            flush()
            finished = true
            try? handle?.close()
            handle = nil
        } else if buffer.count >= 64 * 1024 {
            flush()
        }
    }

    private func line(t: Int, event: RecordingEvent) -> Data? {
        guard var data = try? encoder.encode(RecordingLine(t: t, event: event)) else { return nil }
        data.append(0x0A)
        return data
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        defer { buffer.removeAll(keepingCapacity: true) }
        guard let handle else { return }
        // A vanished directory leaves an unlinked file: the write succeeds into nothing, or fails; either way it is dropped.
        do {
            try handle.write(contentsOf: buffer)
            written += buffer.count
        } catch {}
    }

    func close() {
        flush()
        finished = true
        try? handle?.close()
        handle = nil
    }
}

@MainActor
final class Recorder {
    let url: URL
    private let queue = DispatchQueue(label: "portico.diagnostics.recorder")
    private let writer: RecordingWriter
    private let timer: DispatchSourceTimer
    private let began = DispatchTime.now().uptimeNanoseconds
    private var closed = false

    init(chat: Int, directory: URL, startedAt: Date = .now, cap: Int = 20_000_000) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // File-name safe: colons and the fractional point become dashes' neighbours (`21-05-00.250Z`).
        let stamp = formatter.string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        let made = RecordingWriter.create(directory: directory, stem: "\(chat)-\(stamp)")
        url = made.url
        let writer = RecordingWriter(handle: made.handle, cap: cap)
        self.writer = writer
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        // `@Sendable`: written in a @MainActor init, the closure would otherwise be inferred
        // @MainActor and trap (SE-0423) when the queue runs it.
        timer.setEventHandler { @Sendable in writer.flush() }
        timer.resume()
    }

    /// A recorder dropped without `close()` still flushes what it holds.
    deinit {
        timer.cancel()
        let writer = writer
        queue.async { writer.close() }
    }

    /// Stamps `t` and hands the event to the queue; the main thread does nothing else.
    func note(_ event: RecordingEvent) {
        guard !closed else { return }
        let t = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
        let writer = writer
        queue.async { writer.append(t: t, event: event) }
    }

    /// Waits for everything noted so far to be handled (tests).
    func drain() { queue.sync {} }

    func close() {
        guard !closed else { return }
        closed = true
        timer.cancel()
        let writer = writer
        queue.sync { writer.close() }
    }

    nonisolated static func read(_ url: URL) throws -> [(t: Int, event: RecordingEvent)] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let l = try decoder.decode(RecordingLine.self, from: Data(line.utf8))
            return (t: l.t, event: l.event)
        }
    }
}
