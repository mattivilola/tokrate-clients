import Combine
import Foundation
import Sparkle

enum UpdaterConfiguration {
    static let feedURL = "https://tokrate.dev/updates/macos/stable.xml"

    static func isConfigured(info: [String: Any]) -> Bool {
        guard info["SUFeedURL"] as? String == feedURL,
              let publicKey = info["SUPublicEDKey"] as? String,
              let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return false
        }

        return keyData.count == 32
    }
}

/// Where an update package may be downloaded from. The appcast is signed, but Sparkle itself takes
/// each package URL from it without restriction; Tokrate publishes its releases on one GitHub
/// repository only, so an item that points anywhere else is ignored.
enum UpdateDownloadPolicy {
    static let host = "github.com"
    static let pathPrefix = "/mattivilola/tokrate-clients/releases/download/"

    /// Whether `url` is `https://github.com/mattivilola/tokrate-clients/releases/download/...`: HTTPS,
    /// that host with no credentials or port, and a path under the release downloads that does not climb out of it.
    static func permits(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == host,
              components.user == nil, components.password == nil, components.port == nil
        else { return false }
        let path = components.path
        guard path.hasPrefix(pathPrefix), path.count > pathPrefix.count else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." }
    }

    /// An appcast item is usable when its package, and the package of each of its delta updates, comes from the release repository.
    static func permits(_ item: SUAppcastItem) -> Bool {
        permits(item.fileURL) && (item.deltaUpdates ?? [:]).values.allSatisfy { permits($0.fileURL) }
    }
}

/// Ignores appcast items whose packages are not hosted by the release repository (`UpdateDownloadPolicy`).
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        // A feed of permitted items only is left to Sparkle's own choice, with all its rules.
        guard appcast.items.contains(where: { !UpdateDownloadPolicy.permits($0) }) else { return nil }
        let host = updater.hostBundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        let comparator = SUStandardVersionComparator.default
        let best = appcast.items
            .filter { item in
                UpdateDownloadPolicy.permits(item) && item.channel == nil && !item.isInformationOnlyUpdate
                    && item.minimumOperatingSystemVersionIsOK && item.maximumOperatingSystemVersionIsOK
                    && item.arm64HardwareRequirementIsOK && item.minimumUpdateVersionIsOK
                    && comparator.compareVersion(host, toVersion: item.versionString) == .orderedAscending
            }
            .max { comparator.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedAscending }
        return best ?? SUAppcastItem.empty()
    }
}

@MainActor
final class AppUpdates: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController?
    /// Sparkle keeps its delegate weakly.
    private let updaterDelegate = UpdaterDelegate()
    private var cancellables = Set<AnyCancellable>()

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        guard UpdaterConfiguration.isConfigured(info: info) else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        updaterController = controller

        // Keep update metadata limited to the versioned feed request.
        controller.updater.sendsSystemProfile = false
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)
        controller.startUpdater()
    }

    var isAvailable: Bool { updaterController != nil }

    var automaticallyChecksForUpdates: Bool {
        updaterController?.updater.automaticallyChecksForUpdates ?? false
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
