import Foundation
import Observation

@MainActor
public protocol SharingPreferenceStore: AnyObject {
    var sharingEnabled: Bool? { get set }
}

/// An absent preference means sharing is on; an explicit off choice survives relaunches.
@MainActor
public final class UserDefaultsSharingPreferenceStore: SharingPreferenceStore {
    public static let key = "communitySharingEnabled"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var sharingEnabled: Bool? {
        get { defaults.object(forKey: Self.key) as? Bool }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Separates the saved switch position from actual availability (for example, a locked Keychain).
@MainActor @Observable
public final class SharingPreferences {
    public let session: SharingSession
    public private(set) var isSharingRequested: Bool
    @ObservationIgnored private let store: any SharingPreferenceStore
    @ObservationIgnored private var didActivate = false

    public init(session: SharingSession, store: any SharingPreferenceStore = UserDefaultsSharingPreferenceStore()) {
        self.session = session
        self.store = store
        isSharingRequested = store.sharingEnabled ?? true
    }

    /// Called from the application launch delegate, independently of all windows and menu content.
    public func activate(now: Date = .now, startPolling: Bool = true) {
        guard !didActivate else { return }
        didActivate = true
        if isSharingRequested { session.enable(now: now, startPolling: startPolling) }
        else { session.disable() }
    }

    public func setSharingEnabled(_ enabled: Bool, now: Date = .now, startPolling: Bool = true) {
        store.sharingEnabled = enabled
        isSharingRequested = enabled
        if enabled { session.enable(now: now, startPolling: startPolling) }
        else { session.disable() }
    }

    public func retry(now: Date = .now, startPolling: Bool = true) {
        guard isSharingRequested else { return }
        session.enable(now: now, startPolling: startPolling)
    }
}
