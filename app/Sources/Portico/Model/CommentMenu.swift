import Foundation

// MARK: - CommentMenu (v0.23)

/// The viewer's own context menu, replacing WebKit's: Comment, a divider,
/// Cut, Copy and Paste, a divider, Select All. Formatting comes later.
enum CommentMenu {
    struct Context: Equatable {
        var editMode: Bool
        var hasSelection: Bool
        /// Why the file can't take comments (read-only), if so.
        var readOnly: String?
        /// Why the selection can't be anchored, if so.
        var refusal: String?
    }

    struct Item: Equatable {
        var title: String
        var symbol: String? = nil
        /// The shortcut's key, with Command.
        var key: String? = nil
        var enabled = true
        var tip: String? = nil
        var isDivider = false

        static let divider = Item(title: "", isDivider: true)
    }

    static let noSelectionTip = "Select text to comment on it."

    static func items(_ c: Context) -> [Item] {
        let commentTip: String? = !c.hasSelection ? noSelectionTip : (c.readOnly ?? c.refusal)
        return [
            Item(title: "Comment", symbol: "plus.bubble", enabled: commentTip == nil, tip: commentTip),
            .divider,
            Item(title: "Cut", key: "x", enabled: c.editMode && c.hasSelection),
            Item(title: "Copy", key: "c", enabled: c.hasSelection),
            Item(title: "Paste", key: "v", enabled: c.editMode),
            .divider,
            Item(title: "Select All", key: "a"),
        ]
    }
}
