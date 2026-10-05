import CryptoKit
import Foundation
import TokrateCore
import XCTest

@MainActor
private final class MemorySharingPreference: SharingPreferenceStore {
    var sharingEnabled: Bool?
    var consentRecord: SharingConsentRecord?
    init(_ value: Bool? = nil, consentRecord: SharingConsentRecord? = nil) {
        sharingEnabled = value
        self.consentRecord = consentRecord
    }
}

private final class PreferenceIdentity: SharingIdentity, @unchecked Sendable {
    private let lock = NSLock()
    private let key = Curve25519.Signing.PrivateKey().rawRepresentation
    private var failure = false
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func setFailure(_ value: Bool) { lock.withLock { failure = value } }
    func loadOrCreate() throws -> Data {
        try lock.withLock {
            count += 1
            if failure { throw Failure.unavailable }
            return key
        }
    }
    private enum Failure: Error { case unavailable }
}

private actor PreferenceTransport: SharingTransport {
    private var requests = 0
    func count() -> Int { requests }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests += 1
        if request.httpMethod == "POST" { return (Data(), 202) }
        return (Data(#"{"schemaVersion":1,"generatedAt":null,"dataAsOf":null,"collectionEnabled":true,"state":"insufficient_data","window":"15m","cohorts":[],"alerts":[]}"#.utf8), 200)
    }
}

@MainActor
final class SharingPreferencesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_020_401)
    private func metric(_ id: String, at date: Date) -> TurnMetric {
        TurnMetric(id: id, completedAt: date, model: "reported-model", outputTokens: 100, durationSeconds: 10, codexTTFTSeconds: nil, turnThroughputTPS: 10)
    }

    func testFirstLaunchStaysLocalUntilAffirmativeConsentAndNeverBackfillsHistory() async {
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        let session = SharingSession(identity: identity, transport: transport)
        let preference = MemorySharingPreference()
        let model = SharingPreferences(session: session, store: preference)
        XCTAssertFalse(model.isSharingRequested)
        XCTAssertTrue(model.isConsentDisclosureVisible)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(identity.calls, 0)
        model.activate(now: now, startPolling: false)
        model.activate(now: now.addingTimeInterval(20), startPolling: false)
        session.enqueue([metric("before-consent", at: now.addingTimeInterval(10))], now: now.addingTimeInterval(20))
        model.retry(now: now.addingTimeInterval(20), startPolling: false)
        await session.refresh(now: now.addingTimeInterval(20))
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(identity.calls, 0)
        let beforeConsentRequests = await transport.count()
        XCTAssertEqual(beforeConsentRequests, 0)

        let acceptedAt = now.addingTimeInterval(30)
        model.consentToShare(now: acceptedAt, startPolling: false)
        XCTAssertFalse(model.isConsentDisclosureVisible)
        XCTAssertTrue(model.isSharingRequested)
        XCTAssertTrue(session.isEnabled)
        XCTAssertEqual(identity.calls, 1)
        XCTAssertEqual(preference.consentRecord, SharingConsentRecord(
            noticeVersion: SharingPreferences.currentNoticeVersion,
            decidedAt: acceptedAt,
            action: .contribute
        ))
        session.enqueue([
            metric("historical", at: now.addingTimeInterval(-1)),
            metric("before-consent-2", at: now.addingTimeInterval(29)),
            metric("after-consent", at: now.addingTimeInterval(31))
        ], now: now.addingTimeInterval(40))
        XCTAssertEqual(session.pendingCount, 1, "Repeated activation must not move the original launch boundary")
        await session.refresh(now: now.addingTimeInterval(40))
        let count = await transport.count()
        XCTAssertEqual(count, 2)
    }

    func testLegacyDefaultOnWithoutConsentRequiresReconfirmation() async {
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        let session = SharingSession(identity: identity, transport: transport)
        let preference = MemorySharingPreference(true)
        let model = SharingPreferences(session: session, store: preference)

        XCTAssertFalse(model.isSharingRequested)
        XCTAssertTrue(model.isConsentDisclosureVisible)
        model.activate(now: now, startPolling: false)
        model.setSharingEnabled(true, now: now, startPolling: false)
        XCTAssertTrue(model.isConsentDisclosureVisible)
        XCTAssertTrue(preference.sharingEnabled == true, "Legacy preference is retained until the user makes a current choice")
        XCTAssertNil(preference.consentRecord)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(identity.calls, 0)
        let requests = await transport.count()
        XCTAssertEqual(requests, 0)
    }

    func testPersistedOffSurvivesNewModelAndMakesNoRequestsOrIdentityAccess() async {
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        let preference = MemorySharingPreference(false)
        for _ in 0..<2 {
            let session = SharingSession(identity: identity, transport: transport)
            let model = SharingPreferences(session: session, store: preference)
            model.activate(now: now, startPolling: false)
            model.retry(now: now, startPolling: false)
            session.enqueue([metric("ignored", at: now)], now: now)
            await session.refresh(now: now)
            XCTAssertFalse(model.isSharingRequested)
            XCTAssertFalse(model.isConsentDisclosureVisible)
            XCTAssertFalse(session.isEnabled)
            XCTAssertEqual(session.pendingCount, 0)
        }
        XCTAssertEqual(identity.calls, 0)
        let count = await transport.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(preference.sharingEnabled, false)
    }

    func testLocalOnlyDecisionPersistsAndLaterEnableRequiresConsent() async {
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        let preference = MemorySharingPreference()
        let first = SharingPreferences(session: SharingSession(identity: identity, transport: transport), store: preference)
        first.chooseLocalOnly(now: now)
        XCTAssertEqual(preference.sharingEnabled, false)
        XCTAssertEqual(preference.consentRecord?.noticeVersion, SharingPreferences.currentNoticeVersion)
        XCTAssertEqual(preference.consentRecord?.action, .localOnly)
        XCTAssertEqual(preference.consentRecord?.decidedAt, now)

        let relaunchedSession = SharingSession(identity: identity, transport: transport)
        let relaunched = SharingPreferences(session: relaunchedSession, store: preference)
        relaunched.activate(now: now.addingTimeInterval(10), startPolling: false)
        XCTAssertFalse(relaunched.isConsentDisclosureVisible)
        XCTAssertFalse(relaunchedSession.isEnabled)
        relaunched.setSharingEnabled(true, now: now.addingTimeInterval(20), startPolling: false)
        XCTAssertTrue(relaunched.isConsentDisclosureVisible)
        XCTAssertFalse(relaunched.isSharingRequested)
        XCTAssertFalse(relaunchedSession.isEnabled)
        XCTAssertEqual(preference.sharingEnabled, false)
        XCTAssertEqual(identity.calls, 0)
        let requests = await transport.count()
        XCTAssertEqual(requests, 0)

        relaunched.consentToShare(now: now.addingTimeInterval(30), startPolling: false)
        XCTAssertTrue(relaunched.isSharingRequested)
        XCTAssertTrue(relaunchedSession.isEnabled)
        XCTAssertEqual(identity.calls, 1)
    }

    func testSwitchOffPersistsAndReenableStartsANewEligibilityWindow() async {
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        let preference = MemorySharingPreference()
        let firstSession = SharingSession(identity: identity, transport: transport)
        let first = SharingPreferences(session: firstSession, store: preference)
        first.activate(now: now, startPolling: false)
        first.consentToShare(now: now, startPolling: false)
        firstSession.enqueue([metric("pending", at: now)], now: now)
        first.setSharingEnabled(false)
        XCTAssertEqual(preference.sharingEnabled, false)
        XCTAssertEqual(preference.consentRecord?.action, .localOnly)
        XCTAssertFalse(firstSession.isEnabled)
        XCTAssertEqual(firstSession.pendingCount, 0)
        XCTAssertNil(firstSession.board)

        let relaunchedSession = SharingSession(identity: identity, transport: transport)
        let relaunched = SharingPreferences(session: relaunchedSession, store: preference)
        relaunched.activate(now: now.addingTimeInterval(20), startPolling: false)
        XCTAssertFalse(relaunchedSession.isEnabled)
        relaunched.setSharingEnabled(true, now: now.addingTimeInterval(30), startPolling: false)
        XCTAssertEqual(preference.sharingEnabled, false, "Requesting enable must not change the saved choice")
        XCTAssertTrue(relaunched.isConsentDisclosureVisible)
        relaunched.consentToShare(now: now.addingTimeInterval(30), startPolling: false)
        XCTAssertEqual(preference.sharingEnabled, true)
        relaunchedSession.enqueue([
            metric("while-off", at: now.addingTimeInterval(25)),
            metric("after-enable", at: now.addingTimeInterval(31))
        ], now: now.addingTimeInterval(31))
        XCTAssertEqual(relaunchedSession.pendingCount, 1)
        XCTAssertTrue(relaunched.isSharingRequested)
        XCTAssertTrue(relaunchedSession.isEnabled)
        await relaunchedSession.refresh(now: now.addingTimeInterval(31))
        let count = await transport.count()
        XCTAssertEqual(count, 2)
    }

    func testKeychainFailureKeepsRequestedOnAndCanRetryWithoutBackfill() async {
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        identity.setFailure(true)
        let preference = MemorySharingPreference()
        let session = SharingSession(identity: identity, transport: transport)
        let model = SharingPreferences(session: session, store: preference)
        model.activate(now: now, startPolling: false)
        XCTAssertTrue(model.isConsentDisclosureVisible)
        model.consentToShare(now: now, startPolling: false)
        XCTAssertTrue(model.isSharingRequested)
        XCTAssertFalse(session.isEnabled)
        XCTAssertTrue(session.status.contains("Keychain"))
        XCTAssertEqual(preference.sharingEnabled, true)
        XCTAssertEqual(preference.consentRecord?.action, .contribute)
        await session.refresh(now: now)
        let before = await transport.count()
        XCTAssertEqual(before, 0)
        identity.setFailure(false)
        model.retry(now: now.addingTimeInterval(30), startPolling: false)
        XCTAssertTrue(session.isEnabled)
        XCTAssertEqual(identity.calls, 2)
        session.enqueue([
            metric("during-failure", at: now.addingTimeInterval(10)),
            metric("after-retry", at: now.addingTimeInterval(31))
        ], now: now.addingTimeInterval(31))
        XCTAssertEqual(session.pendingCount, 1)
    }

    func testOutdatedContributionConsentRequiresCurrentNotice() async {
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        let oldRecord = SharingConsentRecord(
            noticeVersion: SharingPreferences.currentNoticeVersion - 1,
            decidedAt: now.addingTimeInterval(-100),
            action: .contribute
        )
        let preference = MemorySharingPreference(true, consentRecord: oldRecord)
        let session = SharingSession(identity: identity, transport: transport)
        let model = SharingPreferences(session: session, store: preference)

        XCTAssertFalse(model.isSharingRequested)
        XCTAssertTrue(model.isConsentDisclosureVisible)
        model.activate(now: now, startPolling: false)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(identity.calls, 0)
        let requests = await transport.count()
        XCTAssertEqual(requests, 0)
    }

    func testNoticeVersionThreePausesOlderContributionUntilTheUserChooses() async {
        XCTAssertEqual(SharingPreferences.currentNoticeVersion, 3)
        let identity = PreferenceIdentity(), transport = PreferenceTransport()
        let versionOne = SharingConsentRecord(noticeVersion: 1, decidedAt: now.addingTimeInterval(-100), action: .contribute)
        let preference = MemorySharingPreference(true, consentRecord: versionOne)
        let session = SharingSession(identity: identity, transport: transport)
        let model = SharingPreferences(session: session, store: preference)

        // Paused: no identity access and no community requests until the user decides again.
        XCTAssertFalse(model.isSharingRequested)
        XCTAssertTrue(model.isConsentDisclosureVisible)
        model.activate(now: now, startPolling: false)
        await session.refresh(now: now)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(identity.calls, 0)
        let paused = await transport.count()
        XCTAssertEqual(paused, 0)

        model.consentToShare(now: now, startPolling: false)
        XCTAssertTrue(model.isSharingRequested)
        XCTAssertFalse(model.isConsentDisclosureVisible)
        XCTAssertEqual(preference.consentRecord?.noticeVersion, 3)
        XCTAssertEqual(preference.consentRecord?.action, .contribute)

        // Choosing local use also records the current notice and stays off.
        let other = MemorySharingPreference(true, consentRecord: versionOne)
        let localOnly = SharingPreferences(session: SharingSession(identity: PreferenceIdentity(), transport: PreferenceTransport()), store: other)
        localOnly.chooseLocalOnly(now: now)
        XCTAssertEqual(other.consentRecord?.noticeVersion, 3)
        XCTAssertEqual(other.sharingEnabled, false)
        XCTAssertFalse(localOnly.isSharingRequested)
    }

    func testSavedOptOutStaysOffAcrossTheNoticeVersionBump() {
        for record in [
            SharingConsentRecord(noticeVersion: 1, decidedAt: now, action: .localOnly),
            nil
        ] {
            let model = SharingPreferences(
                session: SharingSession(identity: PreferenceIdentity(), transport: PreferenceTransport()),
                store: MemorySharingPreference(false, consentRecord: record)
            )
            XCTAssertFalse(model.isSharingRequested)
            XCTAssertFalse(model.isConsentDisclosureVisible, "a saved OFF is never converted into a prompt or into consent")
        }
        // A version 1 local-only record without a saved switch also stays off.
        let localOnly = SharingPreferences(
            session: SharingSession(identity: PreferenceIdentity(), transport: PreferenceTransport()),
            store: MemorySharingPreference(nil, consentRecord: SharingConsentRecord(noticeVersion: 1, decidedAt: now, action: .localOnly))
        )
        XCTAssertFalse(localOnly.isSharingRequested)
        XCTAssertFalse(localOnly.isConsentDisclosureVisible)
        // First launch and legacy default-on (no record) still show the notice.
        let legacy = SharingPreferences(
            session: SharingSession(identity: PreferenceIdentity(), transport: PreferenceTransport()),
            store: MemorySharingPreference(true, consentRecord: nil)
        )
        XCTAssertTrue(legacy.isConsentDisclosureVisible)
        XCTAssertFalse(legacy.isSharingRequested)
        let fresh = SharingPreferences(
            session: SharingSession(identity: PreferenceIdentity(), transport: PreferenceTransport()),
            store: MemorySharingPreference(nil, consentRecord: nil)
        )
        XCTAssertTrue(fresh.isConsentDisclosureVisible)
    }

    func testCurrentNoticeContributionConsentStaysOnAfterRelaunch() {
        let record = SharingConsentRecord(noticeVersion: SharingPreferences.currentNoticeVersion, decidedAt: now, action: .contribute)
        let model = SharingPreferences(
            session: SharingSession(identity: PreferenceIdentity(), transport: PreferenceTransport()),
            store: MemorySharingPreference(true, consentRecord: record)
        )
        XCTAssertTrue(model.isSharingRequested)
        XCTAssertFalse(model.isConsentDisclosureVisible)
    }

    func testUserDefaultsStorePersistsNoticeVersionTimeAndAction() {
        let suiteName = "TokrateConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharingPreferenceStore(defaults: defaults)
        let record = SharingConsentRecord(noticeVersion: 1, decidedAt: now, action: .contribute)

        store.sharingEnabled = true
        store.consentRecord = record

        let restoredStore = UserDefaultsSharingPreferenceStore(defaults: defaults)
        XCTAssertEqual(restoredStore.sharingEnabled, true)
        XCTAssertEqual(restoredStore.consentRecord, record)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsSharingPreferenceStore.consentVersionKey) as? Int, 1)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsSharingPreferenceStore.consentActionKey), "contribute")
        XCTAssertEqual(defaults.object(forKey: UserDefaultsSharingPreferenceStore.consentDateKey) as? Date, now)
    }
}
