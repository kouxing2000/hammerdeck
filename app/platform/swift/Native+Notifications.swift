// Native.swift split: this file is one domain slice of the `Native` seam (see
// Native.swift for the class, shared state, and installBindings).
// System-level notifications: the macOS Notification Center, as opposed to the
// in-app Toast banner in Native+Panels.swift. The `notify` effect lets each rule
// choose which channel it wants. Delivery goes through the tiny ObjC shim
// (HammerdeckNotify) that uses the permission-free NSUserNotification path -- the
// same approach as Hammerspoon's hs.notify.

import Foundation
import CLua
import HammerdeckNotify

extension Native {
    /// Post a system notification (Notification Center). Pushes a bool: whether it
    /// was delivered. False under `swift run` (no app bundle to attribute it to),
    /// so the Lua seam falls back to the in-app banner -- the system path needs the
    /// packaged `.app`.
    func systemNotify(_ L: OpaquePointer?) -> Int32 {
        let delivered = HDPostSystemNotification(LuaState.string(L, 1) ?? "",
                                                 LuaState.string(L, 2))
        lua_pushboolean(L, delivered ? 1 : 0)
        return 1
    }
}
