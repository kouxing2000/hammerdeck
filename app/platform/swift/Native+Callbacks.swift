// Native.swift split: callback-lifetime helpers for the seam -- the
// makeRef -> hop-to-main -> callRef -> releaseRef dance every async / observer
// binding shares. Centralized so a missed releaseRef (a leaked pinned Lua
// registry ref -- the host's most error-prone bug) can't recur per call site.
// See Native.swift for the class, shared state, and installBindings.

import AppKit
import CLua

extension Native {
    /// Fire a ONE-SHOT async callback on the main actor, then release its ref.
    /// Call from any thread (a URLSession / Process completion already off-main)
    /// -- it marshals to main itself. `push` runs on main and returns the arg
    /// count, exactly like callRef's pushArgs. Referencing Native.shared inside
    /// (rather than capturing the non-Sendable LuaState) keeps the escaping
    /// closure's capture clean, as the hand-rolled sites did. `nonisolated` so a
    /// background URLSession / Process completion can call it directly -- hopping
    /// to main is exactly what it does.
    nonisolated static func fireCallback(_ ref: Int32,
                                         push: @escaping @Sendable (OpaquePointer) -> Int32) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Native.shared.lua.callRef(ref, pushArgs: push)
                Native.shared.lua.releaseRef(ref)
            }
        }
    }

    /// Observe `names` on `center` (a NotificationCenter, or its
    /// DistributedNotificationCenter subclass), invoking the pinned Lua `ref` on
    /// each post; returns the cancel closure (remove every observer + releaseRef)
    /// that the resource map stores. The shared body of every notification-backed
    /// system event -- one place the observe / callRef / removeObserver /
    /// releaseRef quartet lives, so a case can't drift or drop the releaseRef.
    static func bindObserver(_ center: NotificationCenter, _ names: [Notification.Name],
                             _ ref: Int32) -> () -> Void {
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Native.shared.lua.callRef(ref) }
            }
        }
        return {
            for t in tokens { center.removeObserver(t) }
            Native.shared.lua.releaseRef(ref)
        }
    }
}
