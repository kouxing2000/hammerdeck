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

    // MARK: - Cancelable one-shots

    /// Pin `ref` as a CANCELABLE async one-shot and return the resource id to
    /// hand back to Lua (`native.stop(id)` cancels it).
    ///
    /// WHY this exists: an async seam call (http, download, JXA, favicon scan)
    /// pins a Lua callback and fires it whenever the work lands -- which can be
    /// long AFTER the feature that asked for it was disabled. Unguarded that is a
    /// real lifecycle hole, not a theoretical one: bing_daily chains
    /// httpGet -> downloadFile -> setWallpaper, so disabling it mid-flight still
    /// changed the user's wallpaper afterwards. "Disabled" has to mean disabled.
    ///
    /// Registering the in-flight call as a resource closes it. ctx tracks the
    /// returned handle in the feature's enablement scope, so teardown calls
    /// stop() -> `cancel` aborts the underlying work and the pinned ref is
    /// released; a late landing then finds the id gone and drops silently
    /// (see fireOneShot). `cancel` defaults to a no-op for work that cannot be
    /// aborted -- dropping the callback is still the point.
    ///
    /// Reserve-then-arm (rather than one call) so the id is a `let` the completion
    /// closure captures BY VALUE: the canceller needs the task, and the task's
    /// completion needs the id, and a captured `var` closing that loop would be a
    /// cross-thread mutable capture. Arming after the work is created is safe --
    /// fireOneShot lands via main.async, which cannot run until this synchronous
    /// main-actor call has returned.
    func allocOneShot() -> Int32 { allocId() }

    func armOneShot(_ id: Int32, _ ref: Int32, cancel: @escaping () -> Void = {}) {
        cancellers[id] = {
            cancel()
            Native.shared.lua.releaseRef(ref)
        }
    }

    /// Fire a one-shot reserved by `allocOneShot` + `armOneShot`, if it is still live.
    ///
    /// Race-free by construction: the liveness check and every teardown both run
    /// on the main actor, so a completion that races a disable either finds the id
    /// present (fires, then retires it) or absent (drops). Consuming the id BEFORE
    /// calling into Lua matters -- the callback may re-enter and stop its own
    /// handle, which would otherwise release the ref twice.
    nonisolated static func fireOneShot(_ id: Int32, _ ref: Int32,
                                        push: @escaping @Sendable (OpaquePointer) -> Int32) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let native = Native.shared
                guard native.cancellers[id] != nil else { return }   // torn down: drop it
                native.freeResource(id)                              // consume before firing
                native.lua.callRef(ref, pushArgs: push)
                native.lua.releaseRef(ref)
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
