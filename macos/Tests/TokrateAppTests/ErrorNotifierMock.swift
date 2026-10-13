import TokrateCore
@testable import TokrateApp

/// Stands in for the notification center: it answers the permission questions it is told to and
/// records what is posted.
@MainActor
final class MockErrorNotifier: ErrorNotifying {
    var currentPermission: NotificationPermission
    /// What the permission is once the user has answered the system prompt.
    var permissionAfterRequest: NotificationPermission
    private(set) var requestCount = 0
    private(set) var posted: [ErrorNotification] = []

    init(permission: NotificationPermission = .allowed, afterRequest: NotificationPermission = .allowed) {
        currentPermission = permission
        permissionAfterRequest = afterRequest
    }

    func permission() async -> NotificationPermission { currentPermission }

    func requestAuthorization() async {
        requestCount += 1
        currentPermission = permissionAfterRequest
    }

    func post(_ notification: ErrorNotification) async { posted.append(notification) }
}
