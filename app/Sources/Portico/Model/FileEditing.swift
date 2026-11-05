import Darwin
import Foundation

// MARK: - What can be edited (v0.20 §2.1)

/// How the editor shows a file: Markdown as the page, or text and code.
enum EditMode: String, Equatable, Sendable {
    case markdown
    case code
}

/// Whether the viewer's Edit switch can be turned on for a file, and how;
/// or why not, in words for the switch's tip.
enum Editability: Equatable {
    case editable(mode: EditMode, language: String?)
    case readOnly(reason: String)

    var canEdit: Bool {
        if case .editable = self { return true }
        return false
    }
}

/// A file's modification date and size: what the app saw when it loaded or
/// last saved it. A different stamp on disk means someone else wrote it.
struct FileStamp: Equatable, Sendable {
    let modified: Date?
    let size: Int64

    /// The stamp of the file at `url` now; `nil` when it can't be read.
    static func of(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(attributes)
    }

    init(modified: Date?, size: Int64) {
        self.modified = modified
        self.size = size
    }

    init(_ attributes: [FileAttributeKey: Any]) {
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// A file's line endings, as found when it was loaded.
enum LineEnding: Equatable, Sendable {
    case lf
    case crlf

    /// CRLF when the first line break is one; LF otherwise (and with none).
    static func detect(_ text: String) -> LineEnding {
        guard let index = text.utf8.firstIndex(of: 0x0A) else { return .lf }
        guard index > text.utf8.startIndex else { return .lf }
        return text.utf8[text.utf8.index(before: index)] == 0x0D ? .crlf : .lf
    }
}

/// A file read for editing.
struct EditableText: Equatable, Sendable {
    /// The text, without a byte-order mark.
    let text: String
    let stamp: FileStamp
    let lineEnding: LineEnding
    let trailingNewline: Bool
    /// The file started with a UTF-8 byte-order mark (written back as it was).
    let byteOrderMark: Bool
}

enum FileEditing {
    /// Larger files open read-only (§2.1).
    static let sizeLimit: Int64 = 2 * 1024 * 1024

    static let tooLarge = "Too large to edit here"
    static let spaceReason = "The agent keeps this space; ask it to change it"
    static let webReason = "Web pages can't be edited here"
    static let tableReason = "Tables can't be edited here yet"
    static let kindReason = "This kind of file can't be edited here"
    static let missingReason = "This file isn't on this Mac"

    /// Whether `shown` can be edited, and as what (§2.1): Markdown as the
    /// page; plain text, code and HTML as text. Spaces, sites, tables,
    /// images, PDFs and documents are read-only, and so is anything over 2 MB.
    static func editability(for shown: ArtifactPresentation) -> Editability {
        if shown.artifact.id.hasPrefix(AppModel.spaceArtifactPrefix) { return .readOnly(reason: spaceReason) }
        guard let file = shown.fileURL, shown.artifact.kind != .url, shown.media != .url else {
            return .readOnly(reason: webReason)
        }
        let mode: EditMode
        let language: String?
        switch shown.media {
        case .markdown:
            mode = .markdown
            language = "markdown"
        case .html:
            mode = .code
            language = "html"
        case .text:
            if shown.tableSeparator != nil { return .readOnly(reason: tableReason) }
            mode = .code
            language = shown.fileExtension.isEmpty ? nil : shown.fileExtension
        case .url:
            return .readOnly(reason: webReason)
        case .image, .pdf, .other:
            return .readOnly(reason: kindReason)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return .readOnly(reason: missingReason)
        }
        if FileStamp(attributes).size > sizeLimit { return .readOnly(reason: tooLarge) }
        return .editable(mode: mode, language: language)
    }

    // MARK: reading

    enum Failure: Swift.Error, Equatable, CustomStringConvertible {
        case notText
        case tooLarge
        case missing
        case changedOnDisk
        case noPermission
        case diskFull
        case other(String)

        /// The reason as the header shows it after "Not saved — ".
        var description: String {
            switch self {
            case .notText: "it isn't UTF-8 text"
            case .tooLarge: "it's larger than 2 MB"
            case .missing: "the file is gone"
            case .changedOnDisk: "the file changed on disk"
            case .noPermission: "no permission to write it"
            case .diskFull: "the disk is full"
            case .other(let reason): reason
            }
        }

        static func from(_ error: any Swift.Error) -> Failure {
            if let failure = error as? Failure { return failure }
            let ns = error as NSError
            if ns.domain == NSPOSIXErrorDomain {
                switch Int32(ns.code) {
                case EACCES, EPERM, EROFS: return .noPermission
                case ENOSPC, EDQUOT: return .diskFull
                case ENOENT: return .missing
                default: break
                }
            }
            if ns.domain == NSCocoaErrorDomain {
                switch ns.code {
                case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                    return .noPermission
                case NSFileWriteOutOfSpaceError: return .diskFull
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .missing
                default: break
                }
                if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                    return from(underlying)
                }
            }
            return .other(ns.localizedDescription)
        }
    }

    /// The file at `url` as text to edit: UTF-8, at most 2 MB.
    static func read(_ url: URL) throws -> EditableText {
        let target = url.resolvingSymlinksInPath()
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: target.path) } catch { throw Failure.missing }
        let stamp = FileStamp(attributes)
        guard stamp.size <= sizeLimit else { throw Failure.tooLarge }
        let data: Data
        do { data = try Data(contentsOf: target) } catch { throw Failure.from(error) }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard let text = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { throw Failure.notText }
        return EditableText(
            text: text, stamp: stamp, lineEnding: LineEnding.detect(text),
            trailingNewline: text.hasSuffix("\n"), byteOrderMark: bom)
    }

    // MARK: writing (§2.5)

    /// Write `text` to `url` atomically: a temporary file in the same folder,
    /// then `rename(2)`, so the file is the old one or the new one and never
    /// half of either. The file's POSIX permissions are kept. A link is
    /// written through to the file it points at.
    ///
    /// The text is written as it is: the editor hands back the file's own
    /// line endings and its trailing newline (or none) untouched, so an
    /// unchanged text is the same bytes. Nothing is converted here; a
    /// second conversion would rewrite lines nobody edited.
    ///
    /// `preserving` is the stamp the app last saw. A different one on disk
    /// means someone else wrote the file since: nothing is written and
    /// `Failure.changedOnDisk` is thrown (§2.6). Returns the new stamp.
    @discardableResult
    static func write(
        _ text: String, to url: URL, preserving stamp: FileStamp, byteOrderMark: Bool = false
    ) throws -> FileStamp {
        try write(text, to: url, preserving: stamp, byteOrderMark: byteOrderMark, beforeRename: {})
    }

    /// `beforeRename` runs once the temporary file is complete (tests make
    /// it throw, to show the file is left as it was).
    @discardableResult
    static func write(
        _ text: String, to url: URL, preserving stamp: FileStamp, byteOrderMark: Bool = false,
        beforeRename: () throws -> Void
    ) throws -> FileStamp {
        let target = url.resolvingSymlinksInPath()
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: target.path) } catch { throw Failure.missing }
        guard FileStamp(attributes) == stamp else { throw Failure.changedOnDisk }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value

        var data = Data()
        if byteOrderMark { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(text.utf8))

        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).saving")
        var moved = false
        defer { if !moved { try? FileManager.default.removeItem(at: temporary) } }
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EACCES : errno))
            }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: temporary.path)
            }
            try beforeRename()
            guard Darwin.rename(temporary.path, target.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            moved = true
        } catch {
            throw Failure.from(error)
        }
        return FileStamp.of(target) ?? FileStamp(modified: nil, size: Int64(data.count))
    }
}

// MARK: - EditSession

/// One file being edited: the newest text, what was last saved, and the
/// save state the header shows. The editor debounces typing (800 ms) and
/// sends the text; every text that arrives is saved. Saves run one at a
/// time, off the main thread.
@MainActor
final class EditSession: ObservableObject, Identifiable {
    enum SaveState: Equatable {
        case saved
        case saving
        case failed(String)
        /// Autosave held back (the agent changed the file; Task 3).
        case paused
    }

    typealias Writer = @Sendable (_ text: String, _ url: URL, _ stamp: FileStamp, _ bom: Bool) throws -> FileStamp

    @Published var state: SaveState = .saved
    let url: URL
    let mode: EditMode
    let language: String?
    let loaded: EditableText
    /// The file's stamp when loaded, then after each save.
    var baseline: FileStamp
    /// The newest text the editor sent.
    private(set) var text: String
    /// The text on disk, as far as the app knows.
    private(set) var savedText: String
    /// The editor said there are edits it hasn't sent yet (`dirty`).
    private(set) var editorDirty = false
    /// Asks the editor for its text now (set by the editor pane), so an
    /// end inside the 800 ms debounce saves the last keystrokes too.
    var currentText: (() async -> String?)?
    private let writer: Writer
    private weak var registry: EditSessions?
    private var inFlight: Task<Void, Never>?

    init(
        url: URL, loaded: EditableText, mode: EditMode, language: String?,
        writer: @escaping Writer = { try FileEditing.write($0, to: $1, preserving: $2, byteOrderMark: $3) },
        registry: EditSessions? = EditSessions.shared
    ) {
        self.url = url
        self.loaded = loaded
        self.mode = mode
        self.language = language
        self.baseline = loaded.stamp
        self.text = loaded.text
        self.savedText = loaded.text
        self.writer = writer
        self.registry = registry
        registry?.add(self)
    }

    /// Text that isn't on disk yet, sent or not.
    var hasUnsavedText: Bool { editorDirty || text != savedText }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Whether a change on disk may replace the editor's text (§2.6, Task 3).
    /// The editor's own `pending` means only "not sent yet": once it has sent
    /// the text, the edit is this session's. So never while a save is
    /// running or failed, or while any text is unsaved.
    var mayReplaceFromDisk: Bool {
        inFlight == nil && state == .saved && !hasUnsavedText
    }

    /// The editor's text was replaced with `force` (Task 3): that cancels
    /// its unsent edit with no `changed` to follow, so the flag goes too.
    func editorForceReplaced() {
        editorDirty = false
    }

    /// The editor's first edit since a load or a save.
    func markDirty() {
        editorDirty = true
    }

    /// The editor sent its text (typing stopped, or it lost focus): save it.
    func textChanged(_ newText: String) {
        text = newText
        editorDirty = false
        Task { await self.saveNow() }
    }

    /// Save the newest text now, after any save already running. One
    /// attempt: a failure stays `.failed(reason)` with the text kept,
    /// until the next edit or Retry.
    func saveNow() async {
        if let running = inFlight { await running.value }
        if state == .paused { return }
        guard text != savedText else {
            if isFailed || state == .saving { state = .saved }
            return
        }
        let task = Task { await self.writeOnce() }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func writeOnce() async {
        let snapshot = text, url = url, stamp = baseline, bom = loaded.byteOrderMark, writer = writer
        state = .saving
        let result: Result<FileStamp, FileEditing.Failure> = await offMain {
            do { return .success(try writer(snapshot, url, stamp, bom)) } catch { return .failure(.from(error)) }
        }
        switch result {
        case .success(let stamp):
            baseline = stamp
            savedText = snapshot
            if text == savedText { state = .saved }
        case .failure(let failure):
            state = .failed(failure.description)
        }
    }

    /// Done editing (Edit off, another file, the viewer closed, quitting):
    /// the editor's last text is fetched and saved. False when it couldn't
    /// be saved; the text stays here and the session stays registered.
    func end() async -> Bool {
        if let currentText, let latest = await currentText(), latest != text {
            text = latest
        }
        editorDirty = false
        await saveNow()
        if isFailed || state == .paused || text != savedText { return false }
        registry?.remove(self)
        return true
    }

    /// The quit was held because this couldn't be saved: the header says so.
    func noteQuitHeld() {
        if case .failed(let reason) = state, !reason.hasSuffix(EditSessions.quitAgain) {
            state = .failed(reason + EditSessions.quitAgain)
        }
    }
}

/// Every edit session alive, so quitting can save each first.
@MainActor
final class EditSessions {
    static let shared = EditSessions()
    static let quitAgain = "; quit again to quit without saving"

    private var sessions: [ObjectIdentifier: WeakSession] = [:]

    private struct WeakSession {
        weak var session: EditSession?
    }

    init() {}

    var all: [EditSession] {
        sessions = sessions.filter { $0.value.session != nil }
        return sessions.values.compactMap(\.session)
    }

    func add(_ session: EditSession) {
        sessions[ObjectIdentifier(session)] = WeakSession(session: session)
    }

    func remove(_ session: EditSession) {
        sessions[ObjectIdentifier(session)] = nil
    }

    /// `end()` on every session; true when all saved.
    func endAll() async -> Bool {
        var saved = true
        for session in all where !(await session.end()) {
            saved = false
            session.noteQuitHeld()
        }
        return saved
    }
}

/// What a quit does once the edit sessions have been ended (Review Focus 4).
/// No alert: an alert would block automation. A failed save cancels the
/// first quit and the header says why; a second quit goes ahead anyway.
enum QuitGate {
    enum Decision: Equatable { case quit, cancel }

    static func decide(saved: Bool, alreadyHeld: Bool) -> Decision {
        saved || alreadyHeld ? .quit : .cancel
    }
}
