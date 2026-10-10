import Sparkle
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

    func testOnlyPackagesOnTheReleaseRepositoryOfGitHubOverHTTPSAreDownloaded() {
        let base = "https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.22/Tokrate-0.1.22-macos-arm64.zip"
        XCTAssertTrue(UpdateDownloadPolicy.permits(URL(string: base)))
        XCTAssertTrue(UpdateDownloadPolicy.permits(URL(string: "https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.22/Tokrate%200.1.22.zip")))
        for rejected in [
            "http://github.com/mattivilola/tokrate-clients/releases/download/v0.1.22/Tokrate.zip",
            "https://github.com/mattivilola/other-repo/releases/download/v1/Tokrate.zip",
            "https://github.com/someone-else/tokrate-clients/releases/download/v1/Tokrate.zip",
            "https://github.com/mattivilola/tokrate-clients/releases/latest",
            "https://github.com/mattivilola/tokrate-clients/releases/download/",
            "https://github.com/mattivilola/tokrate-clients/releases/download",
            "https://github.com/mattivilola/tokrate-clients/archive/refs/heads/main.zip",
            "https://github.com/mattivilola/tokrate-clients/releases/download/../../../../evil/x/raw/Tokrate.zip",
            "https://github.com/mattivilola/tokrate-clients/releases/download/v1/%2E%2E/%2E%2E/evil.zip",
            "https://github.com.evil.example/mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip",
            "https://evil.example/github.com/mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip",
            "https://user@github.com/mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip",
            "https://github.com:8443/mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip",
            "https://www.github.com/mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip",
            "https://objects.githubusercontent.com/mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip",
            "https://tokrate.dev/downloads/Tokrate.zip",
            "ftp://github.com/mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip",
            "file:///mattivilola/tokrate-clients/releases/download/v1/Tokrate.zip"
        ] {
            XCTAssertFalse(UpdateDownloadPolicy.permits(URL(string: rejected)), rejected)
        }
        XCTAssertFalse(UpdateDownloadPolicy.permits(nil as URL?))
    }

    func testAnAppcastItemIsUsableOnlyWhenItsPackageAndItsDeltasAreOnTheReleaseRepository() throws {
        func item(_ url: String, deltas: [String] = []) throws -> SUAppcastItem {
            var enclosure: [String: Any] = ["url": url, "sparkle:version": "9", "sparkle:shortVersionString": "9.0", "length": "100", "sparkle:edSignature": "x"]
            enclosure["type"] = "application/octet-stream"
            var dictionary: [String: Any] = ["enclosure": enclosure, "title": "Version 9"]
            if !deltas.isEmpty {
                dictionary["sparkle:deltas"] = deltas.enumerated().map { index, delta in
                    ["url": delta, "sparkle:version": "9", "sparkle:deltaFrom": "\(index + 1)", "length": "10", "sparkle:edSignature": "x"] as [String: Any]
                }
            }
            return try XCTUnwrap(SUAppcastItem(dictionary: dictionary))
        }
        let good = "https://github.com/mattivilola/tokrate-clients/releases/download/v9/Tokrate-9.zip"
        let goodDelta = "https://github.com/mattivilola/tokrate-clients/releases/download/v9/Tokrate-8-9.delta"
        XCTAssertTrue(UpdateDownloadPolicy.permits(try item(good)))
        XCTAssertFalse(UpdateDownloadPolicy.permits(try item("https://example.com/Tokrate-9.zip")))
        XCTAssertTrue(UpdateDownloadPolicy.permits(try item(good, deltas: [goodDelta])))
        XCTAssertFalse(UpdateDownloadPolicy.permits(try item(good, deltas: [goodDelta, "https://example.com/Tokrate-8-9.delta"])))
    }
}
