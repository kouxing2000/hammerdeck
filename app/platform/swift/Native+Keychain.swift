// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Secrets storage in the macOS login Keychain (generic passwords).
//
// These are thin Lua wrappers: the actual SecItem ops live in KeychainBox (the
// shared accessor), which SettingsStore's config UI also calls -- both ends use
// the SAME service + account so what Settings writes is what ctx.secret reads.
// The Lua side passes the full account string (the `hammerdeck.opt.<id>.<key>`
// namespace UserDefaults options use).

import Foundation
import CLua

extension Native {
    // MARK: - Keychain (generic passwords)

    // (account) -> string | nil. Missing item or any failure reads as nil.
    func keychainGet(_ L: OpaquePointer?) -> Int32 {
        guard let account = LuaState.string(L, 1) else {
            return luaError(L, "keychain_get: account required")
        }
        if let value = KeychainBox.get(account) {
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
        lua_pushboolean(L, KeychainBox.set(account, value) ? 1 : 0)
        return 1
    }

    // (account) -> bool. Deleting a missing item still reports success.
    func keychainDelete(_ L: OpaquePointer?) -> Int32 {
        guard let account = LuaState.string(L, 1) else {
            return luaError(L, "keychain_delete: account required")
        }
        lua_pushboolean(L, KeychainBox.delete(account) ? 1 : 0)
        return 1
    }
}
