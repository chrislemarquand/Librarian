import Cocoa

#if SWIFT_PACKAGE
@MainActor
final class SystemNotificationService {
    static let shared = SystemNotificationService()
    private init() {}

    func prepare() {}

    func postIfBackground(title: String, body: String, identifier: String) {
        _ = (title, body, identifier)
    }
}
#else
import UserNotifications

@MainActor
final class SystemNotificationService {
    static let shared = SystemNotificationService()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    func prepare() {
        Task { [center] in
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func postIfBackground(title: String, body: String, identifier: String) {
        guard !NSApp.isActive else { return }
        Task { [center] in
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus != .denied else { return }
            if settings.authorizationStatus == .notDetermined {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else { return }
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "\(AppBrand.identifierPrefix).\(identifier)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
#endif
