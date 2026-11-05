import AppKit
import Foundation

/// What a composer attaches, by name (v0.19 spec §8.1).
enum Attachment {
    /// The extensions shown as thumbnails. Whether one reaches the agent as
    /// an image is the gateway's call (it reads the bytes, spec §8.3).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    static func isImage(path: String) -> Bool {
        imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// A message's attachments split as the bubble and the composer draw
    /// them: images as thumbnails, everything else as chips. Order is kept.
    static func split(_ paths: [String]) -> (images: [String], files: [String]) {
        (paths.filter { isImage(path: $0) }, paths.filter { !isImage(path: $0) })
    }
}

/// Pasted image data has no file behind it, so the app writes one
/// (v0.19 spec §8.2). Before a send the chat is not certain (the start
/// screen's next session is only a prediction), so a paste is written to
/// `<home>/attachments/pending/<yyyyMMdd-HHmmss-SSS>.png`; when the message
/// goes, its pending files move to `<home>/attachments/<chat>/` for the
/// chat it went to (`adopt`). A chat's folder goes when its history does
/// (`remove`); pending files left over (never sent) are pruned at launch.
enum PastedImages {
    enum Failure: Error, Equatable {
        /// The data is not an image AppKit can read.
        case notAnImage
        /// No home folder is known (no supervisor): nothing is written.
        case noHome
    }

    static let pendingMaxAge: TimeInterval = 7 * 24 * 60 * 60

    static func root(home: URL) -> URL {
        home.appendingPathComponent("attachments", isDirectory: true)
    }

    static func folder(chat: Int, home: URL) -> URL {
        root(home: home).appendingPathComponent(String(chat), isDirectory: true)
    }

    static func pendingFolder(home: URL) -> URL {
        root(home: home).appendingPathComponent("pending", isDirectory: true)
    }

    /// Write `data` (PNG, or TIFF and other image data, converted to PNG)
    /// to the pending folder and return the file's path.
    static func save(_ data: Data, home: URL, now: Date) throws -> String {
        let png = try pngData(data)
        let folder = pendingFolder(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = unique(stampFormatter.string(from: now), ext: "png", in: folder)
        try png.write(to: url, options: .atomic)
        return url.path
    }

    /// The paths a message goes with, its pending files moved into `chat`'s
    /// folder. Other paths are unchanged; a file that cannot be moved keeps
    /// its pending path (it still exists, so the send still works).
    static func adopt(_ paths: [String], chat: Int, home: URL) -> [String] {
        let pending = pendingFolder(home: home).standardizedFileURL.path
        let target = folder(chat: chat, home: home)
        return paths.map { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.deletingLastPathComponent().path == pending else { return path }
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let name = url.deletingPathExtension().lastPathComponent
                let destination = unique(name, ext: url.pathExtension, in: target)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination.path
            } catch {
                return path
            }
        }
    }

    /// Remove the chat's pasted images (its history was removed).
    static func remove(chat: Int, home: URL) {
        try? FileManager.default.removeItem(at: folder(chat: chat, home: home))
    }

    /// Remove pending files older than `maxAge` (pasted, never sent); at launch.
    static func prunePending(home: URL, now: Date, maxAge: TimeInterval = pendingMaxAge) {
        let folder = pendingFolder(home: home)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > maxAge { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// `<name>.<ext>` in `folder`, or `<name>-2.<ext>`… when taken (two pastes in one millisecond).
    private static func unique(_ name: String, ext: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name)-\(counter).\(ext)")
            counter += 1
        }
        return url
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func pngData(_ data: Data) throws -> Data {
        if data.prefix(pngSignature.count) == pngSignature { return data }
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
            let png = rep.representation(using: .png, properties: [:])
        else { throw Failure.notAnImage }
        return png
    }

    private static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }
}
