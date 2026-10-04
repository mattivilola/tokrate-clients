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

@MainActor
final class AppUpdates: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        guard UpdaterConfiguration.isConfigured(info: info) else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
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
