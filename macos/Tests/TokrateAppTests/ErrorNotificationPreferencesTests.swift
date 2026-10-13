import XCTest
@testable import TokrateApp

/// The "Notify me when contributors report provider errors" setting: off by default, saved with the other
/// preferences, and switched on only once the system allows notifications.
@MainActor
final class ErrorNotificationPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "tokrate.notifications.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func preferences(_ notifier: MockErrorNotifier) -> ErrorNotificationPreferences {
        ErrorNotificationPreferences(notifier: notifier, defaults: defaults)
    }

    func testOffByDefaultAndNothingIsAskedOfTheSystem() {
        let notifier = MockErrorNotifier(permission: .notDetermined)
        let preferences = preferences(notifier)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertFalse(preferences.isPermissionDenied)
        XCTAssertEqual(notifier.requestCount, 0)
    }

    func testSwitchingOnAsksTheSystemAndStaysOnWhenGranted() async {
        let notifier = MockErrorNotifier(permission: .notDetermined, afterRequest: .allowed)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)
        XCTAssertEqual(notifier.requestCount, 1)
        XCTAssertTrue(preferences.isEnabled)
        XCTAssertFalse(preferences.isPermissionDenied)
        XCTAssertFalse(preferences.isRequesting)
    }

    func testRefusingThePromptKeepsTheSettingOffAndSaysSo() async {
        let notifier = MockErrorNotifier(permission: .notDetermined, afterRequest: .denied)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)
        XCTAssertEqual(notifier.requestCount, 1)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(preferences.isPermissionDenied)
        XCTAssertFalse(defaults.bool(forKey: ErrorNotificationPreferences.defaultsKey))
    }

    func testAlreadyDeniedDoesNotAskAgain() async {
        let notifier = MockErrorNotifier(permission: .denied)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)
        XCTAssertEqual(notifier.requestCount, 0)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(preferences.isPermissionDenied)
    }

    func testAlreadyAllowedDoesNotAskAgain() async {
        let notifier = MockErrorNotifier(permission: .allowed)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)
        XCTAssertEqual(notifier.requestCount, 0)
        XCTAssertTrue(preferences.isEnabled)
    }

    func testProvisionalPermissionIsNotEnough() async {
        // The system reports provisional delivery as not determined; the request leaves it there.
        let notifier = MockErrorNotifier(permission: .notDetermined, afterRequest: .notDetermined)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(preferences.isPermissionDenied)
    }

    func testSwitchingOffIsImmediateAndNeverAsksTheSystem() async {
        let notifier = MockErrorNotifier(permission: .allowed)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)
        await preferences.setEnabled(false)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertEqual(notifier.requestCount, 0)
    }

    func testTheSettingIsSavedWithTheOtherPreferences() async {
        let notifier = MockErrorNotifier(permission: .allowed)
        let first = preferences(notifier)
        await first.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: ErrorNotificationPreferences.defaultsKey))
        XCTAssertTrue(preferences(notifier).isEnabled)

        await first.setEnabled(false)
        XCTAssertFalse(preferences(notifier).isEnabled)
    }

    func testARefusedSwitchOnIsNotSaved() async {
        let notifier = MockErrorNotifier(permission: .denied)
        await preferences(notifier).setEnabled(true)
        XCTAssertFalse(defaults.bool(forKey: ErrorNotificationPreferences.defaultsKey))
        XCTAssertFalse(preferences(notifier).isEnabled)
    }

    func testRefreshSwitchesOffASettingTheSystemHasRevoked() async {
        let notifier = MockErrorNotifier(permission: .allowed)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)

        notifier.currentPermission = .denied
        await preferences.refreshPermission()
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(preferences.isPermissionDenied)
        XCTAssertFalse(defaults.bool(forKey: ErrorNotificationPreferences.defaultsKey))

        // Allowed again in System Settings: the message goes, the setting stays for the user to switch on.
        notifier.currentPermission = .allowed
        await preferences.refreshPermission()
        XCTAssertFalse(preferences.isPermissionDenied)
        XCTAssertFalse(preferences.isEnabled)
    }

    func testRefreshKeepsAnAllowedSettingAndFlagsADeniedOneThatIsOff() async {
        let notifier = MockErrorNotifier(permission: .allowed)
        let preferences = preferences(notifier)
        await preferences.setEnabled(true)
        await preferences.refreshPermission()
        XCTAssertTrue(preferences.isEnabled)

        let denied = ErrorNotificationPreferences(notifier: MockErrorNotifier(permission: .denied), defaults: UserDefaults(suiteName: suite + ".other")!)
        await denied.refreshPermission()
        XCTAssertTrue(denied.isPermissionDenied)
        UserDefaults(suiteName: suite + ".other")!.removePersistentDomain(forName: suite + ".other")
    }
}
