import Foundation
import Observation

public struct SharingConsentRecord: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case contribute
        case localOnly
    }

    public let noticeVersion: Int
    public let decidedAt: Date
    public let action: Action

    public init(noticeVersion: Int, decidedAt: Date, action: Action) {
        self.noticeVersion = noticeVersion
        self.decidedAt = decidedAt
        self.action = action
    }
}

@MainActor
public protocol SharingPreferenceStore: AnyObject {
    var sharingEnabled: Bool? { get set }
    var consentRecord: SharingConsentRecord? { get set }
}

/// An absent preference never grants permission to access a signing identity or the network.
@MainActor
public final class UserDefaultsSharingPreferenceStore: SharingPreferenceStore {
    public static let key = "communitySharingEnabled"
    public static let consentVersionKey = "communitySharingConsentNoticeVersion"
    public static let consentDateKey = "communitySharingConsentDecidedAt"
    public static let consentActionKey = "communitySharingConsentAction"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var sharingEnabled: Bool? {
        get { defaults.object(forKey: Self.key) as? Bool }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
        }
    }

    public var consentRecord: SharingConsentRecord? {
        get {
            guard let version = defaults.object(forKey: Self.consentVersionKey) as? Int,
                  let date = defaults.object(forKey: Self.consentDateKey) as? Date,
                  let rawAction = defaults.string(forKey: Self.consentActionKey),
                  let action = SharingConsentRecord.Action(rawValue: rawAction)
            else { return nil }
            return SharingConsentRecord(noticeVersion: version, decidedAt: date, action: action)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.consentVersionKey)
                defaults.removeObject(forKey: Self.consentDateKey)
                defaults.removeObject(forKey: Self.consentActionKey)
                return
            }
            defaults.set(newValue.noticeVersion, forKey: Self.consentVersionKey)
            defaults.set(newValue.decidedAt, forKey: Self.consentDateKey)
            defaults.set(newValue.action.rawValue, forKey: Self.consentActionKey)
        }
    }
}

/// Separates a saved consent decision from actual availability (for example, a locked Keychain).
@MainActor @Observable
public final class SharingPreferences {
    public static let currentNoticeVersion = 1

    public let session: SharingSession
    public private(set) var isSharingRequested: Bool
    public private(set) var isConsentDisclosureVisible: Bool
    @ObservationIgnored private let store: any SharingPreferenceStore
    @ObservationIgnored private var didActivate = false

    public init(session: SharingSession, store: any SharingPreferenceStore = UserDefaultsSharingPreferenceStore()) {
        self.session = session
        self.store = store

        let savedChoice = store.sharingEnabled
        let record = store.consentRecord
        let hasCurrentContributionConsent = savedChoice == true
            && record?.noticeVersion == Self.currentNoticeVersion
            && record?.action == .contribute
        isSharingRequested = hasCurrentContributionConsent

        if savedChoice == false || (savedChoice != true && record?.action == .localOnly) {
            // An explicit saved opt-out stays off without being converted into opt-in consent.
            isConsentDisclosureVisible = false
        } else {
            // First launches and legacy default-on settings must see the current notice.
            isConsentDisclosureVisible = !hasCurrentContributionConsent
        }
    }

    /// Called from the application launch delegate, independently of all windows and menu content.
    public func activate(now: Date = .now, startPolling: Bool = true) {
        guard !didActivate else { return }
        didActivate = true
        if isSharingRequested { session.enable(now: now, startPolling: startPolling) }
        else { session.disable() }
    }

    /// A switch or other compact control may request the disclosure, but cannot grant consent.
    public func setSharingEnabled(_ enabled: Bool, now: Date = .now, startPolling: Bool = true) {
        if enabled {
            guard !isSharingRequested else { return }
            isConsentDisclosureVisible = true
        } else {
            chooseLocalOnly(now: now)
        }
    }

    /// Records the affirmative action before opening Keychain or starting any community requests.
    public func consentToShare(now: Date = .now, startPolling: Bool = true) {
        store.consentRecord = SharingConsentRecord(
            noticeVersion: Self.currentNoticeVersion,
            decidedAt: now,
            action: .contribute
        )
        store.sharingEnabled = true
        isConsentDisclosureVisible = false
        isSharingRequested = true
        session.enable(now: now, startPolling: startPolling)
    }

    public func chooseLocalOnly(now: Date = .now) {
        store.consentRecord = SharingConsentRecord(
            noticeVersion: Self.currentNoticeVersion,
            decidedAt: now,
            action: .localOnly
        )
        store.sharingEnabled = false
        isConsentDisclosureVisible = false
        isSharingRequested = false
        session.disable()
    }

    public func retry(now: Date = .now, startPolling: Bool = true) {
        guard isSharingRequested else { return }
        session.enable(now: now, startPolling: startPolling)
    }
}
