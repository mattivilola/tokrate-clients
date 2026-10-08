import CryptoKit
import Foundation

extension SHA256 {
    /// The lowercase hex digest of `text`'s UTF-8 bytes: the local pseudonym of an id built from
    /// session, path or message identifiers, which are never kept or shown themselves.
    static func hexDigest(of text: String) -> String {
        hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
