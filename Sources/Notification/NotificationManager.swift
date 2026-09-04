import Foundation
import UserNotifications
import AppKit

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Display a task completion notification.
    public func showTaskDoneNotification(title: String?, cwd: String?) {
        let sessionLabel = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "会话"

        var workspace: String?
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            workspace = URL(fileURLWithPath: cwd).lastPathComponent
        }

        let content = UNMutableNotificationContent()
        content.title = "任务完成"
        if let workspace = workspace {
            content.body = "\(sessionLabel)\n工作区：\(workspace)"
        } else {
            content.body = sessionLabel
        }
        content.sound = .default

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self?.post(content, using: center)
            case .notDetermined:
                // M1 packages are ad-hoc signed. Asking for notification
                // permission from an ad-hoc build creates a system SwiftUI
                // window that aborts in a safe-area constraint loop on
                // macOS 26. Deliver only when permission already exists;
                // a later signed release can expose an explicit opt-in UI.
                return
            case .denied:
                return
            @unknown default:
                return
            }
        }
    }

    private func post(_ content: UNNotificationContent, using center: UNUserNotificationCenter) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                print("[NotificationManager] Failed to post notification:", error)
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            // Match Electron's click behavior: bring the actual DSH window
            // back when it was hidden behind the Dock or the red light.
            MainWindowController.shared.showMainWindow()
            completionHandler()
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
