import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.19 spec §8.1–8.2, §8.4: images in the composer and the message. A
/// drop or paste onto the composer's text attaches; pasted image data is
/// written to a file; the bubble splits thumbnails from file chips.
@MainActor
final class ImageAttachmentTests: XCTestCase {

    private var home: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("image-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("image-attach-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: home)
    }

    private func tiff(side: Int = 4) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.tiffRepresentation!
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // MARK: - names

    func testIsImageByExtension() {
        for path in ["/a/b.png", "/a/b.JPG", "/a/b.jpeg", "/a/b.gif", "/a/b.webp", "/a/b.heic", "/a/b.tiff"] {
            XCTAssertTrue(Attachment.isImage(path: path), path)
        }
        for path in ["/a/b.md", "/a/b.pdf", "/a/b", "/a/png", "/a/b.svg"] {
            XCTAssertFalse(Attachment.isImage(path: path), path)
        }
    }

    // MARK: - pasted image files

    func testSaveWritesAPNGUnderTheChatsFolderAndRemoveDeletesIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.123)
        let path = try PastedImages.save(tiff(), chat: 7, home: home, now: now)
        let url = URL(fileURLWithPath: path)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
            home.appendingPathComponent("attachments/7").standardizedFileURL.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        XCTAssertEqual(url.lastPathComponent, "\(formatter.string(from: now)).png")
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written.prefix(8), Self.pngSignature, "TIFF pasteboard data is converted to PNG")

        // A second paste in the same millisecond keeps both.
        let second = try PastedImages.save(tiff(), chat: 7, home: home, now: now)
        XCTAssertNotEqual(second, path)

        PastedImages.remove(chat: 7, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PastedImages.folder(chat: 7, home: home).path))
    }

    func testSaveRefusesDataThatIsNotAnImage() {
        XCTAssertThrowsError(try PastedImages.save(Data("hello".utf8), chat: 1, home: home, now: Date()))
    }

    func testRemovingASessionRemovesItsPastedImages() throws {
        let model = AppModel()
        model.outbound = { _ in }
        model.attachmentsHome = home
        let path = try model.savePastedImage(tiff(), chat: 3)
        XCTAssertTrue(path.hasPrefix(home.path))
        model.remove(chat: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - the composer's paste handler

    /// A class of the tests' own, so the hook leaves `NSTextView` itself alone.
    private final class PlainTextView: NSTextView {}

    private final class Taken {
        var paths: [String] = []
    }

    private func hookedTextView(_ taken: Taken) -> NSTextView {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.isRichText = false
        let intake = ComposerIntake(
            attach: { taken.paths += $0 },
            saveImage: { [home] data in try PastedImages.save(data, chat: 1, home: home!, now: Date()) })
        intake.pasteboard = pasteboard
        XCTAssertTrue(ComposerTextViewHook.install(on: view, intake: intake))
        return view
    }

    func testPastingImageDataAddsOneAttachmentAndNoText() throws {
        let taken = Taken()
        let view = hookedTextView(taken)
        pasteboard.setData(tiff(), forType: .tiff)
        view.paste(nil)
        XCTAssertEqual(taken.paths.count, 1)
        XCTAssertEqual(view.string, "")
        let path = try XCTUnwrap(taken.paths.first)
        XCTAssertTrue(path.hasPrefix(PastedImages.folder(chat: 1, home: home).path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)).prefix(8), Self.pngSignature)
    }

    func testPastingAPNGFileURLAddsThatPath() throws {
        let file = home.appendingPathComponent("shot.png")
        try PastedImages.pngData(tiff()).write(to: file)
        let taken = Taken()
        let view = hookedTextView(taken)
        pasteboard.writeObjects([file as NSURL])
        view.paste(nil)
        XCTAssertEqual(taken.paths, [file.path])
        XCTAssertEqual(view.string, "", "never the path as text")
    }

    func testPastingPlainTextInsertsTheText() {
        let taken = Taken()
        let view = hookedTextView(taken)
        pasteboard.setString("hello there", forType: .string)
        view.paste(nil)
        XCTAssertEqual(taken.paths, [])
        XCTAssertEqual(view.string, "hello there")
    }

    func testTextWithAPictureOfItPastesAsText() {
        pasteboard.declareTypes([.string, .tiff], owner: nil)
        pasteboard.setString("cells", forType: .string)
        pasteboard.setData(tiff(), forType: .tiff)
        XCTAssertEqual(ComposerIntake.contents(of: pasteboard), .text)
    }

    func testAFolderDropIsTakenAndIgnored() {
        let taken = Taken()
        let intake = ComposerIntake(attach: { taken.paths += $0 }, saveImage: { _ in "" })
        pasteboard.writeObjects([home as NSURL])
        XCTAssertTrue(intake.take(from: pasteboard, dropping: true), "a drop never lands as path text")
        XCTAssertFalse(intake.take(from: pasteboard), "a paste leaves it to the text view")
        XCTAssertEqual(taken.paths, [])
    }

    /// The real composer: `TextEditor`'s own text view is found and hooked.
    func testTheTextEditorsTextViewIsFoundAndHooked() throws {
        let taken = Taken()
        let intake = ComposerIntake(attach: { taken.paths += $0 }, saveImage: { _ in "" })
        intake.pasteboard = pasteboard
        struct Editor: View {
            let intake: ComposerIntake
            @State var text = ""
            var body: some View {
                TextEditor(text: $text)
                    .background(ComposerTextViewFinder(intake: intake))
                    .frame(width: 240, height: 80)
            }
        }
        let host = NSHostingView(rootView: Editor(intake: intake))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            for case let sub as NSView in (view.subviews as NSArray) { if let found = textView(in: sub) { return found } }
            return nil
        }
        let text = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(ComposerTextViewHook.isHooked(text))
        XCTAssertTrue(ComposerTextViewHook.intake(of: text) === intake)
        XCTAssertTrue(((text.value(forKey: "registeredDraggedTypes") as? NSArray) ?? []).contains(NSPasteboard.PasteboardType.fileURL.rawValue))

        let file = home.appendingPathComponent("drop.png")
        pasteboard.writeObjects([file as NSURL])
        text.paste(nil)
        XCTAssertEqual(taken.paths, [file.path])
        XCTAssertEqual(text.string, "")
        window.contentView = nil
    }

    /// A text view of the same class without an intake pastes as it always did.
    func testATextViewWithoutAnIntakeIsUntouched() {
        let taken = Taken()
        _ = hookedTextView(taken)
        let other = PlainTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertTrue(ComposerTextViewHook.isHooked(other))
        XCTAssertNil(ComposerTextViewHook.intake(of: other))
        other.insertText("as before", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(other.string, "as before")
    }

    // MARK: - the bubble

    func testBubbleSplitsImagesFromFilesAndShowsTheTypedText() {
        let user = UserText(chat: 1, turn: 2, text: "Compare", attachments: ["/x/a.png", "/x/b.md"])
        let content = BubbleContent(user)
        XCTAssertEqual(content.images, ["/x/a.png"])
        XCTAssertEqual(content.files, ["/x/b.md"])
        XCTAssertEqual(content.text, "Compare")
    }

    func testAnOlderGatewaysTextShowsUnchanged() {
        let text = "Compare\n\nAttached files:\n- /x/a.png"
        let content = BubbleContent(UserText(chat: 1, turn: 2, text: text))
        XCTAssertEqual(content.text, text)
        XCTAssertEqual(content.images, [])
        XCTAssertEqual(content.files, [])
    }

    func testUserTextDecodesAttachments() throws {
        let json = #"{"type":"user.text","chat":1,"turn":2,"text":"Compare","attachments":["/x/a.png"],"ts":"2026-11-04T12:00:00Z"}"#
        guard case .userText(let user) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("expected user.text")
        }
        XCTAssertEqual(user.attachments, ["/x/a.png"])
    }

    func testTheAppAsksForAttachmentsApart() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("messages.attachments.v1"))
    }

    // MARK: - thumbnails

    func testAThumbnailForAMissingFileIsTheMissingPlaceholder() {
        let missing = home.appendingPathComponent("gone.png").path
        let loaded = AttachmentImageCache.shared.load(path: missing)
        XCTAssertEqual(loaded, .missing)
        XCTAssertEqual(AttachmentThumbnail.placeholderSymbol(for: loaded), AttachmentThumbnail.missingSymbol)
        XCTAssertNotEqual(AttachmentThumbnail.missingSymbol, AttachmentThumbnail.loadingSymbol)
    }

    func testAThumbnailLoadsAndIsCachedByPathAndModificationDate() throws {
        let file = home.appendingPathComponent("pic.png")
        try PastedImages.pngData(tiff(side: 4)).write(to: file)
        let first = AttachmentImageCache.shared.load(path: file.path)
        guard case .image = first else { return XCTFail("expected an image") }
        XCTAssertEqual(AttachmentImageCache.shared.load(path: file.path), first, "the same image from the cache")
        XCTAssertNil(AttachmentThumbnail.placeholderSymbol(for: first))

        // Edited: a new modification date loads anew.
        try PastedImages.pngData(tiff(side: 8)).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        let edited = AttachmentImageCache.shared.load(path: file.path)
        XCTAssertNotEqual(edited, first)
    }
}
