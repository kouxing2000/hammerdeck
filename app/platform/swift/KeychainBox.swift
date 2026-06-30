// KeychainBox -- the single login-Keychain accessor for secret options.
//
// Both ends of the secret round-trip share this: the Lua seam
// (Native+Keychain.swift, what ctx.secret reads/writes) and the config UI's
// write side (SettingsStore, the `secret` option editor). They MUST agree on
// service + account string or what Settings writes is not what ctx.secret
// reads, so the storage primitive lives in ONE neutral place rather than being
// re-implemented at each end.
//
// Account string is the full `hammerdeck.opt.<id>.<key>` namespace (same one
// UserDefaults options use); a single fixed service groups our items. Used for
// values that must not sit in plaintext UserDefaults -- currently the OpenAI
// API key text_actions reads via ctx.secret.

import Foundation
import Security

enum KeychainBox {
    static let service = "com.hammerdeck.secrets"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// (account) -> string | nil. Missing item or any failure reads as nil.
    static func get(_ account: String) -> String? {
        #if DEBUG
        // Dev: serve secrets from `.env` so we never hit the login Keychain
        // (which re-prompts on every rebuild for a self-signed binary). See
        // DevEnv.cachedSecret.
        if let value = DevEnv.cachedSecret(account) { return value }
        #endif
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// (account, value) -> bool. Upsert via delete-then-add.
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attrs = baseQuery(account)
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// (account) -> bool. Deleting a missing item still reports success.
    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
