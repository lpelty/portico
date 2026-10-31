import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Where "a space was updated" notifications go. A small protocol so the
/// model can be tested without real notification permission.
@MainActor
protocol SpaceNotifying: AnyObject {
    /// Post a notification for space `space`: `title` is the space's title,
    /// `body` reads "Updated — <time>".
    func post(space: String, title: String, body: String)
}

/// The real thing, on `UNUserNotificationCenter`. macOS asks to allow
/// notifications the first time one is posted. Clicking a notification
/// brings Portico forward and opens the space.
@MainActor
final class SpaceNotifier: NSObject, SpaceNotifying, UNUserNotificationCenterDelegate {
    /// What a click opens; set by the app.
    var open: ((String) -> Void)?
    nonisolated static let spaceKey = "space"

    private var center: UNUserNotificationCenter { .current() }

    /// Become the centre's delegate (needed to hear the click, and so a
    /// notification shows while another window of the app is key).
    func install() {
        center.delegate = self
    }

    func post(space: String, title: String, body: String) {
        let center = center
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [Self.spaceKey: space]
            // One notification per space: a newer one replaces the older.
            center.add(UNNotificationRequest(identifier: "space.\(space)", content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let space = response.notification.request.content.userInfo[Self.spaceKey] as? String
        Task { @MainActor in
            NSApplication.shared.activate()
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let space { self.open?(space) }
        }
        completionHandler()
    }
}
