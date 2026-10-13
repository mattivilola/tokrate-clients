import AppKit
import TokrateCore
import UserNotifications

/// Whether Tokrate may show notifications, as the system settings have it.
enum NotificationPermission: Equatable, Sendable {
    /// Not asked yet, or only provisional (quiet delivery without a banner), which is not enough.
    case notDetermined
    /// The user turned notifications off for Tokrate.
    case denied
    case allowed
}

/// What the error notifications need from the operating system: permission and delivery. A protocol
/// so the store and the preferences are tested with a mock instead of the notification center.
@MainActor
protocol ErrorNotifying: AnyObject {
    func permission() async -> NotificationPermission
    /// Asks the user; read `permission()` afterwards for the answer.
    func requestAuthorization() async
    func post(_ notification: ErrorNotification) async
}

/// Delivers through `UNUserNotificationCenter`. Nothing here touches the notification center before it
/// is needed, and never outside an app bundle (a bare executable has no notification identity and
/// the center raises when asked for), so tests and `swift run` stay quiet.
@MainActor
final class SystemErrorNotifier: NSObject, ErrorNotifying {
    /// Called when the user clicks a notification.
    var onActivate: () -> Void = {}

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Becomes the center's delegate. Called at launch, because a click on a notification can be what
    /// launches the app.
    func activate() {
        center?.delegate = self
    }

    func permission() async -> NotificationPermission {
        guard let center else { return .denied }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: return .allowed
        case .denied, .ephemeral: return .denied
        case .notDetermined, .provisional: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async {
        // Alert only: a banner, without a sound or a badge.
        _ = try? await center?.requestAuthorization(options: [.alert])
    }

    func post(_ notification: ErrorNotification) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = nil
        // The same identifier replaces an older notification of the same model and kind.
        try? await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }
}

extension SystemErrorNotifier: UNUserNotificationCenterDelegate {
    /// Banners also show while Tokrate is frontmost (its popover or a window is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let isClick = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if isClick { self.onActivate() }
            completionHandler()
        }
    }
}

/// The Notifications pane of System Settings, where the user can turn Tokrate's notifications back on.
enum NotificationSettingsLink {
    static let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    @MainActor
    static func open() {
        NSWorkspace.shared.open(url)
    }
}
