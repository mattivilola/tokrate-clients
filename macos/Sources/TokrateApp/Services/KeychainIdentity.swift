import CryptoKit
import Foundation
import Security
import TokrateCore

struct KeychainIdentity: SharingIdentity {
    func loadOrCreate() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.tokrate.installation-signing",
            kSecAttrAccount as String: "ed25519-v1"
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            return data
        }
        guard status == errSecItemNotFound else { throw IdentityError.keychainUnavailable }
        let data = Curve25519.Signing.PrivateKey().rawRepresentation
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw IdentityError.keychainUnavailable }
        return data
    }
    private enum IdentityError: Error { case keychainUnavailable }
}
