import AppKit
import ObjectiveC
import SwiftUI

/// What a composer does with files and image data handed to its text
/// (v0.19 spec §8.1): a file dropped or pasted onto the text becomes an
/// attachment, never its path as text; pasted image data is written to a
/// file first (`PastedImages`). Plain text pastes as before.
@MainActor
final class ComposerIntake: NSObject {
    /// Add these paths to the composer's attachments.
    var attach: ([String]) -> Void
    /// Write pasted image data to a file and return its path.
    var saveImage: (Data) throws -> String
    /// Where ⌘V reads: the general pasteboard, or one a test hands in.
    let pasteboard: NSPasteboard

    init(
        attach: @escaping ([String]) -> Void, saveImage: @escaping (Data) throws -> String,
        pasteboard: NSPasteboard = .general
    ) {
        self.attach = attach
        self.saveImage = saveImage
        self.pasteboard = pasteboard
    }

    /// The image types a drag or paste may carry as data.
    nonisolated static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]

    /// Whether a drag carries something the composer takes, from the
    /// pasteboard's types alone: no data is read and no file looked at
    /// (it is asked on every mouse move). `performDragOperation` reads.
    nonisolated static func offers(types: [NSPasteboard.PasteboardType]) -> Bool {
        if types.contains(.fileURL) { return true }
        return !types.contains(.string) && types.contains(where: imageTypes.contains)
    }

    /// What a pasteboard holds, as the composer reads it.
    enum Contents: Equatable {
        /// File URLs: the files' paths (folders left out; may be empty when only folders came).
        case files([String])
        /// Image data with no text beside it (a screenshot, Preview's Copy).
        case image(Data)
        /// Text, or nothing the composer takes: the text view's own paste.
        case text
    }

    /// File URLs win (Finder's Copy also puts the name as text); then image
    /// data, unless text came with it (a copy from a document app carries
    /// a picture of the text as well).
    static func contents(of pasteboard: NSPasteboard) -> Contents {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return .files(urls.filter { !isDirectory($0) }.map(\.path))
        }
        let types = pasteboard.types ?? []
        if !types.contains(.string), NSImage.canInit(with: pasteboard),
            let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation
        {
            return .image(data)
        }
        return .text
    }

    /// Take what the pasteboard holds as attachments. `true` when it was
    /// taken (nothing goes into the text); `false` leaves it to the text view.
    /// A drop (`dropping`) of folders only is taken and ignored: a path never
    /// lands as text.
    @discardableResult
    func take(from pasteboard: NSPasteboard, dropping: Bool = false) -> Bool {
        switch Self.contents(of: pasteboard) {
        case .files(let paths):
            guard !paths.isEmpty else { return dropping }
            attach(paths)
            return true
        case .image(let data):
            guard let path = try? saveImage(data) else { return false }
            attach([path])
            return true
        case .text:
            return false
        }
    }


    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

/// Hands a composer's drops and pastes to its `ComposerIntake`.
///
/// The composer is SwiftUI's `TextEditor`, whose `NSTextView` takes a file
/// drop itself and inserts the path before any SwiftUI drop destination
/// sees it (the v0.19 field report). Its class is SwiftUI's own
/// (`SwiftUI.PlatformTextView`), so the app cannot subclass it at compile
/// time, and giving the one instance a runtime subclass breaks the
/// Key-Value Observing SwiftUI already set up on it. Instead the text
/// view's class gets `paste:` and the dragging-destination methods
/// replaced once, each gated on an intake attached to the instance: a text
/// view without one (every other `TextEditor`) calls the original at once.
/// Every other behaviour of the editor (Enter, IME, the slash list, focus,
/// voice, text scale) is the `TextEditor`'s, untouched.
@MainActor
enum ComposerTextViewHook {
    private nonisolated(unsafe) static var intakeKey: UInt8 = 0
    /// The classes whose methods are replaced.
    private static var hookedClasses: Set<ObjectIdentifier> = []

    /// The intake installed on this text view, if any.
    nonisolated static func intake(of textView: NSTextView) -> ComposerIntake? {
        objc_getAssociatedObject(textView, &intakeKey) as? ComposerIntake
    }

    /// Whether `textView`'s class, or a class it inherits from, answers
    /// drops and pastes through an intake.
    static func isHooked(_ textView: NSTextView) -> Bool {
        isCovered(baseClass(of: textView))
    }

    /// `cls` or one of its superclasses has the replacements: hooking it
    /// again would only run the gate twice.
    private static func isCovered(_ cls: AnyClass) -> Bool {
        var current: AnyClass? = cls
        while let each = current {
            if hookedClasses.contains(ObjectIdentifier(each)) { return true }
            current = class_getSuperclass(each)
        }
        return false
    }

    /// Point `textView` at `intake` (each call); replace its class's
    /// methods the first time that class is seen.
    @discardableResult
    static func install(on textView: NSTextView, intake: ComposerIntake) -> Bool {
        objc_setAssociatedObject(textView, &intakeKey, intake, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let base: AnyClass = baseClass(of: textView)
        if !isCovered(base) {
            hook(base)
            hookedClasses.insert(ObjectIdentifier(base))
        }
        textView.registerForDraggedTypes(extraDragTypes)
        return true
    }

    static let extraDragTypes: [NSPasteboard.PasteboardType] = [.fileURL] + ComposerIntake.imageTypes

    /// The instance's class under any Key-Value Observing subclass.
    private static func baseClass(of object: AnyObject) -> AnyClass {
        var cls: AnyClass = object_getClass(object) ?? type(of: object)
        while NSStringFromClass(cls).hasPrefix("NSKVONotifying_"), let superclass = class_getSuperclass(cls) {
            cls = superclass
        }
        return cls
    }

    private static func hook(_ cls: AnyClass) {
        typealias Action = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        typealias Operation = @convention(c) (AnyObject, Selector, AnyObject) -> UInt
        typealias Answer = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

        // paste: — attachments first, else the original paste.
        replace(#selector(NSText.paste(_:)), in: cls) { original in
            let block: @convention(block) (NSTextView, AnyObject?) -> Void = { view, sender in
                if let intake = intake(of: view), takePaste(intake, view: view) { return }
                unsafeBitCast(original(), to: Action.self)(view, #selector(NSText.paste(_:)), sender)
            }
            return block
        }
        // Dragging: a drag the intake takes shows Copy and drops as attachments.
        for name in ["draggingEntered:", "draggingUpdated:"] {
            let selector = NSSelectorFromString(name)
            replace(selector, in: cls) { original in
                let block: @convention(block) (NSTextView, AnyObject) -> UInt = { view, info in
                    if takes(info, view: view) { return NSDragOperation.copy.rawValue }
                    return unsafeBitCast(original(), to: Operation.self)(view, selector, info)
                }
                return block
            }
        }
        for name in ["prepareForDragOperation:", "performDragOperation:"] {
            let selector = NSSelectorFromString(name)
            let performs = name == "performDragOperation:"
            replace(selector, in: cls) { original in
                let block: @convention(block) (NSTextView, AnyObject) -> Bool = { view, info in
                    if takes(info, view: view) { return performs ? drop(info, view: view) : true }
                    return unsafeBitCast(original(), to: Answer.self)(view, selector, info)
                }
                return block
            }
        }
        let conclude = NSSelectorFromString("concludeDragOperation:")
        replace(conclude, in: cls) { original in
            let block: @convention(block) (NSTextView, AnyObject?) -> Void = { view, info in
                if let info, takes(info, view: view) { return }
                unsafeBitCast(original(), to: Action.self)(view, conclude, info)
            }
            return block
        }
    }

    /// Replace `selector` on `cls` with the block `make` returns. The block
    /// calls the original through the closure it is handed: the class's own
    /// implementation when it had one, else whatever its superclass answers.
    private static func replace(
        _ selector: Selector, in cls: AnyClass, make: (@escaping () -> IMP) -> Any
    ) {
        guard let inherited = class_getInstanceMethod(cls, selector) else { return }
        let types = method_getTypeEncoding(inherited)
        if let own = ownMethod(selector, of: cls) {
            nonisolated(unsafe) var saved: IMP?
            let imp = imp_implementationWithBlock(make { saved! })
            saved = method_setImplementation(own, imp)
        } else {
            let superclass: AnyClass? = class_getSuperclass(cls)
            nonisolated(unsafe) let parent = superclass
            let imp = imp_implementationWithBlock(make { class_getMethodImplementation(parent, selector)! })
            class_addMethod(cls, selector, imp, types)
        }
    }

    private static func ownMethod(_ selector: Selector, of cls: AnyClass) -> Method? {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return nil }
        defer { free(list) }
        for index in 0..<Int(count) where method_getName(list[index]) == selector {
            return list[index]
        }
        return nil
    }

    // AppKit calls paste and the dragging methods on the main thread.

    /// A paste into a text view with an intake: attachments, else the
    /// intake's pasteboard read into the text as `paste:` reads the general one.
    private nonisolated static func takePaste(_ intake: ComposerIntake, view: NSTextView) -> Bool {
        MainActor.assumeIsolated {
            if !intake.take(from: intake.pasteboard) { view.readSelection(from: intake.pasteboard) }
            return true
        }
    }

    /// Types only: asked on every move of a drag.
    private nonisolated static func takes(_ info: AnyObject, view: NSTextView) -> Bool {
        guard let info = info as? NSDraggingInfo, intake(of: view) != nil else { return false }
        return ComposerIntake.offers(types: info.draggingPasteboard.types ?? [])
    }

    private nonisolated static func drop(_ info: AnyObject, view: NSTextView) -> Bool {
        guard let info = info as? NSDraggingInfo, let intake = intake(of: view) else { return false }
        nonisolated(unsafe) let board = info.draggingPasteboard
        return MainActor.assumeIsolated { intake.take(from: board, dropping: true) }
    }
}

/// Finds the `NSTextView` of the `TextEditor` it sits behind (used as the
/// editor's `.background`) and hooks it to `intake`.
struct ComposerTextViewFinder: NSViewRepresentable {
    let intake: ComposerIntake

    final class Probe: NSView {
        var intake: ComposerIntake?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hookSoon()
        }

        func hookSoon() {
            // The editor's own view may come into the window after this one.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.hook() }
            }
        }

        /// The text view hooked last, to skip the search while it and the intake stand.
        weak var hooked: NSTextView?

        func hook() {
            guard let intake, let window else { return }
            if let hooked, hooked.window === window, ComposerTextViewHook.intake(of: hooked) === intake { return }
            guard let textView = ComposerTextViewFinder.textView(behind: self) else { return }
            ComposerTextViewHook.install(on: textView, intake: intake)
            hooked = textView
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.intake = intake
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.intake = intake
        probe.hookSoon()
    }

    /// The editable text view under `probe`'s frame, searched from its
    /// nearest ancestors outward.
    @MainActor
    static func textView(behind probe: NSView) -> NSTextView? {
        let frame = probe.convert(probe.bounds, to: nil)
        var ancestor = probe.superview
        var depth = 0
        while let current = ancestor, depth < 8 {
            let found = textViews(in: current).filter { view in
                let box = (view.enclosingScrollView ?? view).convert((view.enclosingScrollView ?? view).bounds, to: nil)
                return box.intersects(frame) && frame.contains(NSPoint(x: box.midX, y: box.midY))
            }
            if let best = found.first { return best }
            ancestor = current.superview
            depth += 1
        }
        return nil
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        var out: [NSTextView] = []
        // Read through NSArray: some private AppKit containers hold
        // elements a Swift `[NSView]` refuses to bridge.
        for case let sub as NSView in (view.subviews as NSArray) {
            if let text = sub as? NSTextView, !text.isFieldEditor {
                out.append(text)
            } else {
                out += textViews(in: sub)
            }
        }
        return out
    }
}

/// A composer's one intake, kept across body evaluations; made again only
/// when the composer's chat changes.
@MainActor
final class ComposerIntakeHolder {
    private var kept: (key: Int, intake: ComposerIntake)?

    func intake(for key: Int, make: () -> ComposerIntake) -> ComposerIntake {
        if let kept, kept.key == key { return kept.intake }
        let intake = make()
        kept = (key, intake)
        return intake
    }
}
