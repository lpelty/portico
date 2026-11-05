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
/// (v0.19 spec §8.2): `<home>/attachments/<chat>/<yyyyMMdd-HHmmss-SSS>.png`.
/// The files stay with the session, so History can show them, and go when
/// the session is removed.
enum PastedImages {
    enum Failure: Error, Equatable {
        /// The data is not an image AppKit can read.
        case notAnImage
    }

    static func folder(chat: Int, home: URL) -> URL {
        home.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(String(chat), isDirectory: true)
    }

    /// Write `data` (PNG, or TIFF and other image data, converted to PNG)
    /// under the chat's folder and return the file's path.
    static func save(_ data: Data, chat: Int, home: URL, now: Date) throws -> String {
        let png = try pngData(data)
        let folder = folder(chat: chat, home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = stampFormatter.string(from: now)
        var url = folder.appendingPathComponent("\(stamp).png")
        var counter = 2
        // Two pastes in the same millisecond keep both files.
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stamp)-\(counter).png")
            counter += 1
        }
        try png.write(to: url, options: .atomic)
        return url.path
    }

    /// Remove the chat's pasted images (its history was cleared).
    static func remove(chat: Int, home: URL) {
        try? FileManager.default.removeItem(at: folder(chat: chat, home: home))
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
