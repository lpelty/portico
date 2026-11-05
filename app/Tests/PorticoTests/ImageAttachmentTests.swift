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

    func testSaveWritesAPNGToPendingAdoptMovesItAndRemoveDeletesIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.123)
        let path = try PastedImages.save(tiff(), home: home, now: now)
        let url = URL(fileURLWithPath: path)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
            home.appendingPathComponent("attachments/pending").standardizedFileURL.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        XCTAssertEqual(url.lastPathComponent, "\(formatter.string(from: now)).png")
        XCTAssertEqual(try Data(contentsOf: url).prefix(8), Self.pngSignature, "TIFF pasteboard data is converted to PNG")

        // A second paste in the same millisecond keeps both.
        let second = try PastedImages.save(tiff(), home: home, now: now)
        XCTAssertNotEqual(second, path)

        // Sent to chat 7: pending files move there; other paths stay as they are.
        let adopted = PastedImages.adopt([path, "/x/notes.md", second], chat: 7, home: home)
        XCTAssertEqual(adopted[1], "/x/notes.md")
        for moved in [adopted[0], adopted[2]] {
            XCTAssertEqual(URL(fileURLWithPath: moved).deletingLastPathComponent().standardizedFileURL.path,
                PastedImages.folder(chat: 7, home: home).standardizedFileURL.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        PastedImages.remove(chat: 7, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PastedImages.folder(chat: 7, home: home).path))
    }

    func testSaveRefusesDataThatIsNotAnImage() {
        XCTAssertThrowsError(try PastedImages.save(Data("hello".utf8), home: home, now: Date()))
    }

    func testPruneRemovesPendingFilesOlderThanAWeek() throws {
        let now = Date()
        let old = try PastedImages.save(tiff(), home: home, now: now)
        let fresh = try PastedImages.save(tiff(), home: home, now: now.addingTimeInterval(1))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-6 * 24 * 3600)], ofItemAtPath: fresh)
        PastedImages.prunePending(home: home, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
    }

    private func startModel() throws -> (AppModel, [ClientMessage]) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "image-attach-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        model.attachmentsHome = home
        model.chosenStartFolder = home
        return (model, [])
    }

    /// A paste on the start screen goes with the message to the chat the
    /// gateway made, whatever number was expected.
    func testAStartScreenPasteMovesToTheChatTheMessageWentTo() throws {
        let (model, _) = try startModel()
        var frames: [ClientMessage] = []
        model.outbound = { frames.append($0) }
        model.apply(.chatList(ChatList(chats: [], nextChat: 4)))
        let pasted = try model.savePastedImage(tiff())
        model.attachToStart([pasted])
        // Image only: no words.
        model.startChat(text: "")
        guard case .chatNew(let new)? = frames.last else { return XCTFail("expected chat.new, got \(frames)") }
        model.apply(.chatState(ChatState(chat: 9, state: .idle, id: new.id, seq: 1)))
        guard case .messageSend(let message)? = frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(message.chat, 9)
        XCTAssertEqual(message.text, "")
        let sentPath = try XCTUnwrap(message.attachments.first)
        XCTAssertEqual(URL(fileURLWithPath: sentPath).deletingLastPathComponent().standardizedFileURL.path,
            PastedImages.folder(chat: 9, home: home).standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pasted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PastedImages.folder(chat: 4, home: home).path))
    }

    private func listed(_ chats: [Int]) -> ServerMessage {
        .chatList(ChatList(chats: chats.map {
            ChatSummary(chat: $0, folder: home.path, alias: nil, state: .idle, created: "2026-11-04T12:00:00Z")
        }))
    }

    private final class Frames {
        var all: [ClientMessage] = []
    }

    private func modelWithImages(in chat: Int) throws -> (AppModel, URL, Frames) {
        let model = AppModel()
        let frames = Frames()
        model.outbound = { frames.all.append($0) }
        model.attachmentsHome = home
        model.apply(listed([chat]))
        let folder = PastedImages.folder(chat: chat, home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: folder.appendingPathComponent("a.png"))
        return (model, folder, frames)
    }

    /// A list that leaves a chat out (a partial list during a restart) never deletes its images.
    func testAChatListThatOmitsAChatLeavesItsImages() throws {
        let (model, folder, _) = try modelWithImages(in: 3)
        model.open(chat: 3)
        model.apply(listed([]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAConfirmedRemovalDeletesTheImages() throws {
        let (model, folder, frames) = try modelWithImages(in: 3)
        model.remove(chat: 3)
        guard case .chatRemove? = frames.all.last else { return XCTFail("expected chat.remove") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "not before the gateway answers")
        model.apply(listed([3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "a list still holding it confirms nothing")
        model.apply(listed([]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testARefusedRemovalKeepsTheImages() throws {
        let (model, folder, frames) = try modelWithImages(in: 3)
        model.remove(chat: 3)
        guard case .chatRemove(let request)? = frames.all.last else { return XCTFail("expected chat.remove") }
        model.apply(.error(ErrorMessage(code: "chat.unknown", message: "no chat 3", id: request.id)))
        model.apply(listed([]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testNoHomeWritesNothing() {
        let model = AppModel()
        XCTAssertThrowsError(try model.savePastedImage(tiff()))
    }

    func testAttachmentsAloneCanBeSent() {
        let model = AppModel()
        model.outbound = { _ in }
        XCTAssertTrue(InputBar.showsSendWhileBusy(queues: true, text: " ", attachments: ["/x/a.png"]))
        XCTAssertFalse(InputBar.showsSendWhileBusy(queues: true, text: " ", attachments: []))
        model.setConnection(.connected)
        XCTAssertFalse(InputBar.canSend(model, chat: 1, text: " "), "nothing typed, nothing attached")
        model.attach(["/x/a.png"], to: 1)
        XCTAssertTrue(InputBar.canSend(model, chat: 1, text: ""), "an image alone is a message")
    }

    func testTheStartScreenSendsAttachmentsAlone() throws {
        let (model, _) = try startModel()
        model.outbound = { _ in }
        model.setConnection(.connected)
        XCTAssertFalse(StartView.canSend(model))
        model.attachToStart(["/x/a.png"])
        XCTAssertTrue(StartView.canSend(model))
    }

    // MARK: - the composer's paste handler

    /// A class of the tests' own, so the hook leaves `NSTextView` itself alone.
    private class PlainTextView: NSTextView {}
    private final class ChildTextView: PlainTextView {}

    private final class Taken {
        var paths: [String] = []
    }

    private func hookedTextView(_ taken: Taken) -> NSTextView {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.isRichText = false
        let intake = ComposerIntake(
            attach: { taken.paths += $0 },
            saveImage: { [home] data in try PastedImages.save(data, home: home!, now: Date()) },
            pasteboard: pasteboard)
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
        XCTAssertTrue(path.hasPrefix(PastedImages.pendingFolder(home: home).path))
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
        let intake = ComposerIntake(attach: { taken.paths += $0 }, saveImage: { _ in "" }, pasteboard: pasteboard)
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

    // MARK: - dragging reads types only

    private final class Recorder: NSObject, NSPasteboardItemDataProvider {
        var asked: [NSPasteboard.PasteboardType] = []
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            asked.append(type)
        }
    }

    func testADragIsJudgedFromItsTypesWithoutReadingData() {
        let recorder = Recorder()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(recorder, forTypes: [.fileURL]))
        pasteboard.writeObjects([item])
        XCTAssertTrue(ComposerIntake.offers(types: pasteboard.types ?? []))

        pasteboard.clearContents()
        let image = NSPasteboardItem()
        XCTAssertTrue(image.setDataProvider(recorder, forTypes: [.png]))
        pasteboard.writeObjects([image])
        XCTAssertTrue(ComposerIntake.offers(types: pasteboard.types ?? []))
        XCTAssertEqual(recorder.asked, [], "no data is asked for while dragging")

        XCTAssertFalse(ComposerIntake.offers(types: [.string, .png]), "text with a picture of it stays text")
        XCTAssertFalse(ComposerIntake.offers(types: [.string]))
    }

    /// A subclass of a hooked class is covered by its parent's replacements, not hooked again.
    func testASubclassOfAHookedClassIsNotHookedAgain() {
        let taken = Taken()
        _ = hookedTextView(taken)
        let child = ChildTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertTrue(ComposerTextViewHook.isHooked(child), "covered through PlainTextView")
        let intake = ComposerIntake(attach: { taken.paths += $0 }, saveImage: { _ in "" }, pasteboard: pasteboard)
        ComposerTextViewHook.install(on: child, intake: intake)
        pasteboard.setString("once", forType: .string)
        child.paste(nil)
        XCTAssertEqual(child.string, "once", "the paste ran once, not through two gates")
    }

    func testTheHolderKeepsOneIntakePerChat() {
        let holder = ComposerIntakeHolder()
        var made = 0
        let make = { () -> ComposerIntake in made += 1; return ComposerIntake(attach: { _ in }, saveImage: { _ in "" }) }
        let first = holder.intake(for: 1, make: make)
        XCTAssertTrue(holder.intake(for: 1, make: make) === first)
        XCTAssertFalse(holder.intake(for: 2, make: make) === first)
        XCTAssertEqual(made, 2)
    }
}
