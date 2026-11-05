import AppKit
import ObjectiveC

/// v0.22 item 21: thin overlay scroll bars in every scroll view the app
/// draws (SwiftUI's `ScrollView` and `List` are `NSScrollView`s too), even
/// when the system setting "Show scroll bars" is Always.
///
/// Every `NSScrollView` takes its style from `NSScroller.preferredScrollerStyle`
/// when it is made and again whenever the system preference changes, so
/// answering `.overlay` there, once at launch, is the one place that covers
/// them all, including ones made later in popovers, sheets and Settings.
/// The web views draw their own (viewer.css).
enum OverlayScrollers {
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        let selector = #selector(getter: NSScroller.preferredScrollerStyle)
        guard let method = class_getClassMethod(NSScroller.self, selector) else { return }
        let overlay: @convention(block) (AnyObject) -> Int = { _ in NSScroller.Style.overlay.rawValue }
        method_setImplementation(method, imp_implementationWithBlock(overlay))
        installed = true
    }
}
