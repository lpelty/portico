import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Where "a space was updated" notifications go. A small protocol so the
/// model can be tested without real notification permission.
@MainActor
protocol SpaceNotifying: AnyObject {
    /// Post a notification for space `space`: `title` is the space's title,
    /// `body` reads "Updated — <time>" or the page's `notice` (v0.22).
    /// `target`: the fragment a click scrolls the space to.
    func post(space: String, title: String, body: String, target: String?)
    /// v0.22 (S3): a deployment message's notification; a click only
    /// brings the app forward.
    func postMessage(id: String, title: String, body: String)
}

/// The real thing, on `UNUserNotificationCenter`. macOS asks to allow
/// notifications the first time one is posted. Clicking a notification
/// brings Portico forward and opens the space.
@MainActor
final class SpaceNotifier: NSObject, SpaceNotifying, UNUserNotificationCenterDelegate {
    /// What a click opens, and the fragment to scroll to; set by the app.
    var open: ((String, String?) -> Void)?
    nonisolated static let spaceKey = "space"
    nonisolated static let targetKey = "target"

    private var center: UNUserNotificationCenter { .current() }

    /// Become the centre's delegate (needed to hear the click, and so a
    /// notification shows while another window of the app is key).
    func install() {
        center.delegate = self
    }

    func post(space: String, title: String, body: String, target: String?) {
        var info: [String: String] = [Self.spaceKey: space]
        if let target { info[Self.targetKey] = target }
        // One notification per space: a newer one replaces the older.
        add(identifier: "space.\(space)", title: title, body: body, info: info)
    }

    func postMessage(id: String, title: String, body: String) {
        add(identifier: "message.\(id)", title: title, body: body, info: [:])
    }

    private func add(identifier: String, title: String, body: String, info: [String: String]) {
        let center = center
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = info
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let space = info[Self.spaceKey] as? String
        let target = info[Self.targetKey] as? String
        Task { @MainActor in
            NSApplication.shared.activate()
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let space { self.open?(space, target) }
        }
        completionHandler()
    }
}
