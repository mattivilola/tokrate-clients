import Foundation
import Observation

/// The "Notify me when contributors report provider errors on models I use" setting (contract "Error
/// notifications (0.1.24)"): off by default, saved with the other preferences, and switched on only
/// once the operating system has allowed notifications.
@MainActor @Observable
final class ErrorNotificationPreferences {
    static let defaultsKey = "notifyOnCommunityProviderErrors"

    /// What the user chose. Only `setEnabled` turns it on, after the system allowed notifications.
    private(set) var isEnabled: Bool
    /// The system has notifications turned off for Tokrate, so the setting cannot be on.
    private(set) var isPermissionDenied = false
    /// A switch-on is waiting for the user's answer to the system prompt.
    private(set) var isRequesting = false

    @ObservationIgnored let notifier: any ErrorNotifying
    @ObservationIgnored private let defaults: UserDefaults

    init(notifier: any ErrorNotifying, defaults: UserDefaults) {
        self.notifier = notifier
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    /// Switching off is immediate. Switching on asks the system for permission first, if it has not
    /// been given, and stays off (with `isPermissionDenied`) when the user refuses: provisional
    /// delivery, which shows nothing, does not count as permission.
    func setEnabled(_ enabled: Bool) async {
        guard enabled else {
            store(false)
            return
        }
        guard !isEnabled, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        var permission = await notifier.permission()
        if permission == .notDetermined {
            await notifier.requestAuthorization()
            permission = await notifier.permission()
        }
        isPermissionDenied = permission != .allowed
        if permission == .allowed { store(true) }
    }

    /// Reads the system's current answer, for example when Settings opens or the user comes back from
    /// System Settings. A setting that is on while the system has since turned notifications off is
    /// switched off, so it never claims notifications that cannot arrive.
    func refreshPermission() async {
        let permission = await notifier.permission()
        isPermissionDenied = permission == .denied
        if isEnabled, permission != .allowed { store(false) }
    }

    private func store(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }
}
