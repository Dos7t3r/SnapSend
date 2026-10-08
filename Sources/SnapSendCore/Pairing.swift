import Foundation
import CryptoKit
import Security

public struct PairingChallenge {
    public let code: String
    public let expiresAt: Date
    public private(set) var attempts = 0
    private var consumed = false
    public init(code: String = String(format: "%06d", Int.random(in: 0...999999)), now: Date = Date()) {
        self.code = code; expiresAt = now.addingTimeInterval(60)
    }
    public mutating func verify(_ candidate: String, now: Date = Date()) -> Bool {
        guard now < expiresAt, attempts < 3, !consumed else { return false }
        attempts += 1
        consumed = candidate == code
        return consumed
    }
}
public enum PairingCrypto {
    public static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PairingError.randomFailure }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func proof(secret: String, challenge: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }
    public static func matches(_ candidate: String, secret: String, challenge: String) -> Bool {
        let expected = Array(proof(secret: secret, challenge: challenge).utf8)
        let actual = Array(candidate.utf8)
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public enum PairingError: Error { case randomFailure }
}

/// Long-term pairing material never needs to be typed or exposed in the UI.
public enum PairingVault {
    public static func load() throws -> [String: String] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.status(status) }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    public static func save(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw VaultError.status(added) }
        } else if status != errSecSuccess { throw VaultError.status(status) }
    }
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.snapsend.usb.pairing.v2", kSecAttrAccount as String: "trusted-peers"]
    }
    public enum VaultError: Error { case status(OSStatus) }
}
