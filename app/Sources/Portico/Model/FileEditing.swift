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
    static let permissionReason = "You don't have permission to change this file"

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
        // A link is judged by the file it points at.
        let target = file.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) else {
            return .readOnly(reason: missingReason)
        }
        if FileStamp(attributes).size > sizeLimit { return .readOnly(reason: tooLarge) }
        // A save writes a new file in the folder and renames it over this one.
        guard access(target.path, W_OK) == 0, access(target.deletingLastPathComponent().path, W_OK) == 0 else {
            return .readOnly(reason: permissionReason)
        }
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
        sweepStaleTemporaries(for: target)
        let data: Data
        do { data = try Data(contentsOf: target) } catch { throw Failure.from(error) }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard let text = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { throw Failure.notText }
        return EditableText(
            text: text, stamp: stamp, lineEnding: LineEnding.detect(text),
            trailingNewline: text.hasSuffix("\n"), byteOrderMark: bom)
    }

    // MARK: writing (§2.5)

    /// The temporary file a save writes before the rename:
    /// `.<name>.<8 hex>.saving`, beside the file.
    static func temporaryURL(for target: URL) -> URL {
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(tag).saving")
    }

    /// Whether `name` is one of this file's own leftover temporaries.
    static func isTemporary(_ name: String, for target: URL) -> Bool {
        let prefix = ".\(target.lastPathComponent)."
        guard name.hasPrefix(prefix), name.hasSuffix(".saving") else { return false }
        let tag = name.dropFirst(prefix.count).dropLast(".saving".count)
        return tag.count == 8 && tag.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Temporaries a crashed save left beside the file: removed at load
    /// (only names matching the exact pattern above).
    static func sweepStaleTemporaries(for target: URL) {
        let folder = target.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where isTemporary(name, for: target) {
            unlink(folder.appendingPathComponent(name).path)
        }
    }

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

        let temporary = temporaryURL(for: target)
        var created = false
        var moved = false
        defer { if created && !moved { unlink(temporary.path) } }
        do {
            // Made with the file's own permissions from the start (never
            // wider in between), then set exactly: the umask can't narrow them.
            let mode = mode_t(permissions.map { UInt16(bitPattern: $0) } ?? 0o644) & 0o7777
            let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            created = true
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                _ = fchmod(fd, mode)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // Extended attributes, ACLs and Finder tags come with it; the
            // owner too where the system allows.
            _ = copyfile(target.path, temporary.path, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR))
            if let permissions {
                _ = chmod(temporary.path, mode_t(UInt16(bitPattern: permissions)) & 0o7777)
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
/// sends the text; every text that arrives is saved. Once sent, the edit is
/// this session's: the editor never sends it again, so a failed save is
/// retried from here (Retry, the next edit, Edit off, closing, quitting)
/// and the text stays here until it is on disk. Saves run one at a time,
/// off the main thread.
///
/// The session belongs to `EditSessions` (a strong registry), not to a
/// view: closing, hiding or switching the viewer never drops typed text.
@MainActor
final class EditSession: ObservableObject, Identifiable {
    enum SaveState: Equatable {
        case saved
        case saving
        case failed(String)
        /// Autosave held back: the agent changed the file (§2.6).
        case paused
    }

    enum Conflict: Equatable {
        case agentChanged
    }

    /// How the editor replaces its text (the page's `replaceAll` options).
    struct Replace: Equatable {
        var keepCursorLine = true
        var keepUndo = false
        var force = false
    }

    typealias Writer = @Sendable (_ text: String, _ url: URL, _ stamp: FileStamp, _ bom: Bool) throws -> FileStamp

    @Published var state: SaveState = .saved
    @Published private(set) var conflict: Conflict?
    /// What the header says beside the state: where a recovery copy went,
    /// why a quit was held, that the editor restarted.
    @Published var notice: String?
    let url: URL
    /// The artifact location it was opened for (a path).
    let location: String
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
    /// The chat whose viewer opened it (a held quit brings it forward).
    var chat: Int?
    /// Shown in a viewer now.
    var attached = false
    /// Asks the editor for its text now (set by the editor pane), so an
    /// end inside the 800 ms debounce saves the last keystrokes too. `nil`
    /// (or returning `nil`) when the editor can't answer.
    var currentText: (() async -> String?)?
    /// Replaces the editor's text (the page's `replaceAll`); false when the
    /// editor refused (it has edits not yet sent).
    var editorReplace: ((String, Replace) async -> Bool)?
    /// Where this session's recovery copy is, once one was written.
    private(set) var recoveryURL: URL?
    private let writer: Writer
    private weak var registry: EditSessions?
    private var inFlight: Task<Void, Never>?
    private var recheckAfterSave = false

    init(
        url: URL, location: String? = nil, loaded: EditableText, mode: EditMode, language: String?,
        writer: @escaping Writer = { try FileEditing.write($0, to: $1, preserving: $2, byteOrderMark: $3) },
        registry: EditSessions? = EditSessions.shared
    ) {
        self.url = url
        self.location = location ?? url.path
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

    var name: String { url.lastPathComponent }

    /// Text that isn't on disk yet, sent or not.
    var hasUnsavedText: Bool { editorDirty || text != savedText }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// A save is running.
    var isSaving: Bool { inFlight != nil }

    /// Whether a change on disk may replace the editor's text. The editor's
    /// own `pending` means only "not sent yet": once sent, the edit is this
    /// session's. So never while a save runs or failed, or text is unsaved.
    var mayReplaceFromDisk: Bool {
        inFlight == nil && state == .saved && !hasUnsavedText
    }

    /// The editor's first edit since a load or a send.
    func markDirty() {
        editorDirty = true
    }

    /// The editor sent its text (typing stopped, or it lost focus): save it.
    func textChanged(_ newText: String) {
        text = newText
        editorDirty = false
        Task { await self.saveNow() }
    }

    /// The editor's page restarted (its process ended) and was loaded again
    /// with the text this session holds: what it hadn't sent is gone.
    func editorRestarted() {
        if editorDirty {
            editorDirty = false
            notice = "The editor restarted; your last few seconds of typing may be missing"
        }
    }

    // MARK: saving

    /// Save the newest text now, after any save already running. One
    /// attempt: a failure is `.failed(reason)` with the text kept (and a
    /// recovery copy written), until the next edit or Retry. Paused: nothing.
    func saveNow() async {
        while let running = inFlight { await running.value }
        if state == .paused { return }
        guard text != savedText else {
            if isFailed || state == .saving { state = .saved }
            return
        }
        // Before every save: someone else wrote the file since (§2.6).
        if let disk = FileStamp.of(url), disk != baseline {
            enterConflict()
            return
        }
        let task = Task { [weak self] in
            await self?.writeOnce()
            self?.inFlight = nil
        }
        inFlight = task
        await task.value
        if recheckAfterSave {
            recheckAfterSave = false
            await recheckDisk()
        }
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
            if text == savedText {
                state = .saved
                if recoveryURL != nil || notice != nil { notice = nil }
            }
        case .failure(.changedOnDisk):
            enterConflict()
        case .failure(let failure):
            state = .failed(failure.description)
            writeRecovery()
        }
    }

    /// Done editing (Edit off, another file, the viewer closed or hidden,
    /// quitting): the editor's last text is fetched and saved. False when
    /// it couldn't be: the text stays here, a recovery copy is written, and
    /// the session stays in the registry.
    func end() async -> Bool {
        if let currentText, let latest = await currentText() {
            if latest != text { text = latest }
            editorDirty = false
        }
        if editorDirty {
            // Typing the editor never sent, and it can't be asked now.
            state = .failed("the last edits couldn't be read from the editor")
            writeRecovery()
            return false
        }
        await saveNow()
        if isFailed || state == .paused || text != savedText {
            if isFailed || state == .paused { writeRecovery() }
            return false
        }
        currentText = nil
        editorReplace = nil
        registry?.remove(self)
        return true
    }

    // MARK: the agent changed the file (§2.6)

    /// The file on disk may have changed (an artifact event, a redraw, a
    /// save finishing). `stamp` is what's there now.
    /// - Clean session: the editor reloads in place, keeping the cursor's
    ///   line, and the baseline moves.
    /// - Unsaved text (or a save running or failed): `.paused` with the bar.
    func diskChanged(_ stamp: FileStamp, readText: () throws -> String) async {
        guard stamp != baseline, state != .paused else { return }
        if inFlight != nil {
            // Our own save may be what changed it; look again after.
            recheckAfterSave = true
            return
        }
        guard mayReplaceFromDisk else { return enterConflict() }
        guard let disk = try? readText() else { return }
        if let editorReplace {
            guard await editorReplace(disk, Replace(keepCursorLine: true)) else { return enterConflict() }
        }
        text = disk
        savedText = disk
        baseline = stamp
    }

    /// `diskChanged` with the file as it is now.
    func recheckDisk() async {
        guard let stamp = FileStamp.of(url), stamp != baseline else { return }
        let url = url
        await diskChanged(stamp) { try FileEditing.read(url).text }
    }

    private func enterConflict() {
        conflict = .agentChanged
        state = .paused
    }

    /// Keep mine: the person's text overwrites the agent's.
    func keepMine() async {
        while let running = inFlight { await running.value }
        if let currentText, let latest = await currentText() {
            text = latest
            editorDirty = false
        }
        let snapshot = text, url = url, bom = loaded.byteOrderMark, writer = writer
        guard let disk = FileStamp.of(url) else {
            state = .failed(FileEditing.Failure.missing.description)
            conflict = nil
            writeRecovery()
            return
        }
        state = .saving
        let result: Result<FileStamp, FileEditing.Failure> = await offMain {
            do { return .success(try writer(snapshot, url, disk, bom)) } catch { return .failure(.from(error)) }
        }
        conflict = nil
        switch result {
        case .success(let stamp):
            baseline = stamp
            savedText = snapshot
            state = .saved
            notice = nil
            if text != savedText { await saveNow() }
        case .failure(let failure):
            state = .failed(failure.description)
            writeRecovery()
        }
    }

    /// Use the agent's: the editor shows the file as it is on disk; the
    /// person's edits stay in its undo until Edit goes off.
    func useTheirs() async {
        while let running = inFlight { await running.value }
        let read: EditableText
        do { read = try FileEditing.read(url) } catch {
            state = .failed(FileEditing.Failure.from(error).description)
            return
        }
        if let editorReplace {
            _ = await editorReplace(read.text, Replace(keepCursorLine: true, keepUndo: true, force: true))
        }
        // A forced replace cancels the editor's unsent edit, with no `changed` after.
        editorDirty = false
        text = read.text
        savedText = read.text
        baseline = read.stamp
        conflict = nil
        state = .saved
        notice = nil
    }

    /// Restore a recovery copy's text into the editor and save it.
    func restore(_ restored: String) async {
        if let editorReplace {
            _ = await editorReplace(restored, Replace(keepCursorLine: true, keepUndo: true, force: true))
        }
        editorDirty = false
        text = restored
        await saveNow()
    }

    // MARK: recovery copies

    /// Write the text to `<home>/unsaved/<yyyyMMdd-HHmmss>-<name>` (once per
    /// session, then kept current) and say so. `nil` with no folder set.
    @discardableResult
    func writeRecovery() -> URL? {
        guard let folder = registry?.recoveryFolder else { return nil }
        guard hasUnsavedText || isFailed || state == .paused else { return recoveryURL }
        do {
            let target = try recoveryURL ?? EditRecovery.newURL(for: name, in: folder)
            try EditRecovery.write(text, byteOrderMark: loaded.byteOrderMark, to: target, source: url)
            recoveryURL = target
            notice = "Couldn't save \(name); your edits are kept in \(EditRecovery.display(target))"
            return target
        } catch {
            return nil
        }
    }

    /// The quit was held because this couldn't be saved (Review Focus 4).
    func noteQuitHeld() {
        let folder = registry?.recoveryFolder.map { EditRecovery.display($0) + "/" } ?? "the unsaved folder"
        notice = "Couldn't save \(name) — ⌘Q again quits and keeps your edits in \(folder)"
    }
}

// MARK: - Recovery copies

/// Recovery copies of text that couldn't be saved (fix round 1, ruling B):
/// `<home>/unsaved/<yyyyMMdd-HHmmss>-<name>`, with the original path in an
/// extended attribute, so reopening the file can offer them back.
enum EditRecovery {
    static let sourceAttribute = "com.untypedlabs.edit.source"

    static func newURL(for name: String, in folder: URL, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var candidate = folder.appendingPathComponent("\(stamp)-\(name)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stamp)-\(n)-\(name)")
            n += 1
        }
        return candidate
    }

    static func write(_ text: String, byteOrderMark: Bool, to url: URL, source: URL) throws {
        var data = Data()
        if byteOrderMark { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(text.utf8))
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        let path = Array(source.path.utf8)
        _ = path.withUnsafeBytes { setxattr(url.path, sourceAttribute, $0.baseAddress, $0.count, 0, 0) }
    }

    /// The original path a recovery copy was made for.
    static func source(of url: URL) -> String? {
        let size = getxattr(url.path, sourceAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = bytes.withUnsafeMutableBytes { getxattr(url.path, sourceAttribute, $0.baseAddress, size, 0, 0) }
        guard read == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The newest recovery copy for `file` written after `newerThan` (the
    /// file's modification date), if any.
    static func newest(for file: URL, newerThan: Date?, in folder: URL) -> URL? {
        let path = file.path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var best: (URL, Date)?
        for name in names where name.hasSuffix(file.lastPathComponent) {
            let url = folder.appendingPathComponent(name)
            guard source(of: url) == path,
                  let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  newerThan.map({ date > $0 }) ?? true
            else { continue }
            if best.map({ date > $0.1 }) ?? true { best = (url, date) }
        }
        return best?.0
    }

    /// A path as people write it, `~` for the home folder.
    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - EditSessions

/// Every edit session alive, held strongly: a session leaves only when its
/// text is saved (or the person discards it), never because a view went
/// away. Quitting saves each first.
@MainActor
final class EditSessions {
    static let shared = EditSessions()

    /// `<home>/unsaved`, set at launch from the app's resolved home folder.
    var recoveryFolder: URL?
    /// A quit was held: bring this session's file forward (set by the app).
    var onQuitHeld: ((EditSession) -> Void)?
    private(set) var sessions: [EditSession] = []

    init(recoveryFolder: URL? = nil) {
        self.recoveryFolder = recoveryFolder
    }

    var all: [EditSession] { sessions }

    func add(_ session: EditSession) {
        if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
    }

    func remove(_ session: EditSession) {
        sessions.removeAll { $0 === session }
    }

    /// The person discards a session's text.
    func discard(_ session: EditSession) {
        remove(session)
    }

    /// A session for `location` not shown in any viewer (its text unsaved):
    /// showing the file again picks it back up.
    func waiting(for location: String) -> EditSession? {
        sessions.first { !$0.attached && $0.location == location }
    }

    /// A viewer is editing `location` (a reconnect replay keeps it shown).
    func isEditing(location: String) -> Bool {
        sessions.contains { $0.attached && $0.location == location }
    }

    /// `end()` on every session; true when all saved.
    func endAll() async -> Bool {
        var saved = true
        for session in sessions where !(await session.end()) {
            saved = false
        }
        return saved
    }

    /// The first quit failed: each unsaved file says why, and the first is
    /// brought forward.
    func holdQuit() {
        for session in sessions { session.noteQuitHeld() }
        if let first = sessions.first { onQuitHeld?(first) }
    }

    /// The second quit: every unsaved text goes to a recovery copy.
    func keepAllForQuit() {
        for session in sessions { session.writeRecovery() }
    }
}

/// What a quit does once the edit sessions have been ended (Review Focus 4).
/// No alert: an alert would block automation. A failed save cancels the
/// first quit (the file is brought forward and its header says why); a
/// second quit keeps every unsaved text in a recovery copy and quits.
enum QuitGate {
    enum Decision: Equatable { case quit, keepAndQuit, cancel }

    static func decide(saved: Bool, alreadyHeld: Bool) -> Decision {
        if saved { return .quit }
        return alreadyHeld ? .keepAndQuit : .cancel
    }
}
