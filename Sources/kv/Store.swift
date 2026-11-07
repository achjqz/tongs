import CryptoKit
import Foundation
import Security

struct KVError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct SecretInfo {
    let name: String
    let desc: String
    let modified: Date?
}

/// Secrets are generic-password items in the login keychain, one per name, under one service.
/// The item ACL trusts only the binary that created it, so `security find-generic-password -w`
/// from anything else triggers a macOS password prompt instead of returning the value.
enum Store {
    static let grantKeyAccount = "__kv_grant_key__"

    /// Tests may point at a throwaway service, but only inside kv's own namespace.
    static var service: String {
        if let s = ProcessInfo.processInfo.environment["KV_SERVICE"], s.hasPrefix("dev.kv.") { return s }
        return "dev.kv.secrets"
    }

    static func query(_ name: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let name { q[kSecAttrAccount as String] = name }
        return q
    }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    static func set(_ name: String, value: Data, desc: String?) throws {
        var attrs: [String: Any] = [kSecValueData as String: value]
        if let desc { attrs[kSecAttrComment as String] = desc }
        var status = SecItemUpdate(query(name) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(name).merging(attrs) { $1 }
            add[kSecAttrLabel as String] = "kv: \(name)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KVError("cannot store \(name): \(message(status))") }
    }

    static func exists(_ name: String) -> Bool {
        SecItemCopyMatching(query(name) as CFDictionary, nil) == errSecSuccess
    }

    /// Attributes only: listing never fetches a value, so it never triggers an access prompt.
    static func list() throws -> [SecretInfo] {
        var q = query()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KVError("cannot list secrets: \(message(status))")
        }
        return items.compactMap { item -> SecretInfo? in
            guard let name = item[kSecAttrAccount as String] as? String, name != grantKeyAccount else { return nil }
            return SecretInfo(name: name,
                              desc: item[kSecAttrComment as String] as? String ?? "",
                              modified: item[kSecAttrModificationDate as String] as? Date)
        }.sorted { $0.name < $1.name }
    }

    static func get(_ name: String) throws -> Data {
        var q = query(name)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw KVError("no secret named \(name) (see `kv ls`, or `kv request \(name)`)") }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KVError("cannot read \(name): \(message(status))")
        }
        return data
    }

    static func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess else { throw KVError("cannot delete \(name): \(message(status))") }
    }

    /// HMAC key for the grant file, created on first use and never shown.
    static func grantKey() throws -> SymmetricKey {
        if let data = try? get(grantKeyAccount) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try set(grantKeyAccount, value: key.withUnsafeBytes { Data($0) }, desc: "kv internal: signs approvals")
        return key
    }
}
