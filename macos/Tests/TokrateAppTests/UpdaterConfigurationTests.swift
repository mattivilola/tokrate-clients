import XCTest
@testable import TokrateApp

final class UpdaterConfigurationTests: XCTestCase {
    func testRequiresTheFixedFeedAndAValidEd25519PublicKey() {
        let validKey = Data(repeating: 7, count: 32).base64EncodedString()
        let configured: [String: Any] = [
            "SUFeedURL": UpdaterConfiguration.feedURL,
            "SUPublicEDKey": validKey
        ]

        XCTAssertTrue(UpdaterConfiguration.isConfigured(info: configured))
        XCTAssertFalse(UpdaterConfiguration.isConfigured(info: [
            "SUFeedURL": "https://example.com/updates.xml",
            "SUPublicEDKey": validKey
        ]))
        XCTAssertFalse(UpdaterConfiguration.isConfigured(info: [
            "SUFeedURL": UpdaterConfiguration.feedURL,
            "SUPublicEDKey": "not-base64"
        ]))
        XCTAssertFalse(UpdaterConfiguration.isConfigured(info: [
            "SUFeedURL": UpdaterConfiguration.feedURL,
            "SUPublicEDKey": Data(repeating: 1, count: 31).base64EncodedString()
        ]))
    }
}
