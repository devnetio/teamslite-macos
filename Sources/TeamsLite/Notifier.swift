import AppKit
import UserNotifications

/// macOS banners for incoming messages; clicking one opens the chat.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpenChat: ((String) -> Void)?
    private var configured = false

    /// UNUserNotificationCenter throws when the process isn't running from an app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundlePath.hasSuffix(".app") ? UNUserNotificationCenter.current() : nil
    }

    func setup() {
        guard !configured, let center else { return }
        configured = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { log.error("Notifications unavailable: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func post(chatId: String, title: String, subtitle: String?, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body.isEmpty ? "New message" : body
        content.sound = .default
        content.threadIdentifier = chatId
        content.userInfo = ["chatId": chatId]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func clear(chatId: String) {
        guard let center else { return }
        center.getDeliveredNotifications { list in
            let ids = list.filter { $0.request.content.threadIdentifier == chatId }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func clearAll() {
        center?.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let chatId = response.notification.request.content.userInfo["chatId"] as? String
        Task { @MainActor in
            if let chatId { self.onOpenChat?(chatId) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
