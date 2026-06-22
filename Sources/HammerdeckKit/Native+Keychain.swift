// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Secrets storage in the macOS login Keychain (generic passwords).
//
// Used for values that must NOT sit in plaintext UserDefaults -- currently the
// OpenAI API key the text_actions feature reads via ctx.secret. The Lua side
// passes the full account string (the same `hammerdeck.opt.<id>.<key>`
// namespace UserDefaults options use); a single fixed service groups our items.
// SettingsStore writes these through the SAME service/account so the config UI
// and the Lua read agree (see SettingsStore.KeychainStore).

import Foundation
import Security
import CLua

extension Native {
    // MARK: - Keychain (generic passwords)

    static let keychainService = "com.hammerdeck.secrets"

    private func keychainBaseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Native.keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    // (account) -> string | nil. Missing item or any failure reads as nil.
    func keychainGet(_ L: OpaquePointer?) -> Int32 {
        guard let account = LuaState.string(L, 1) else {
            return luaError(L, "keychain_get: account required")
        }
        #if DEBUG
        // Dev: serve secrets from `.env` so we never hit the login Keychain (which
        // re-prompts on every rebuild for a self-signed binary). See DevEnv.cachedSecret.
        if let value = DevEnv.cachedSecret(account) {
            lua_pushstring(L, value)
            return 1
        }
        #endif
        var query = keychainBaseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            lua_pushstring(L, value)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    // (account, value) -> bool. Upsert via delete-then-add.
    func keychainSet(_ L: OpaquePointer?) -> Int32 {
        guard let account = LuaState.string(L, 1),
              let value = LuaState.string(L, 2) else {
            return luaError(L, "keychain_set: account and value required")
        }
        SecItemDelete(keychainBaseQuery(account: account) as CFDictionary)
        var attrs = keychainBaseQuery(account: account)
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        lua_pushboolean(L, status == errSecSuccess ? 1 : 0)
        return 1
    }

    // (account) -> bool. Deleting a missing item still reports success.
    func keychainDelete(_ L: OpaquePointer?) -> Int32 {
        guard let account = LuaState.string(L, 1) else {
            return luaError(L, "keychain_delete: account required")
        }
        let status = SecItemDelete(keychainBaseQuery(account: account) as CFDictionary)
        lua_pushboolean(L, (status == errSecSuccess || status == errSecItemNotFound) ? 1 : 0)
        return 1
    }
}
