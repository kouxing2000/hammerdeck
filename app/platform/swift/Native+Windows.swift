// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Windows / apps via AXUIElement: listing, focus, frames, screens, mouse.

import AppKit
import CLua

extension Native {
    // MARK: - Windows / apps (AXUIElement)

    // list_windows() -> Lua window handles, MRU-first. The Lua side never sees
    // an AXUIElement: each call rebuilds `axWindowCache` (id -> element, stored
    // on the class -- see Native.swift) and focus_window(id) resolves from it --
    // window_switcher always lists right before focusing, so a one-listing cache
    // is exactly the right lifetime.

    /// Real window enumeration: AXUIElement per app for titles + elements
    /// (Accessibility permission only -- no Screen Recording, which CGWindowList
    /// window NAMES would require), z-ordered via CGWindowList bounds matching
    /// (front-to-back ~= focus recency, the same ordering hs.window.orderedWindows
    /// gives the donor). Returns {} when the permission is missing -- features
    /// check ax_trusted/ax_prompt to onboard.
    func listWindows(_ L: OpaquePointer?) -> Int32 {
        axWindowCache.removeAll()
        guard AXIsProcessTrusted() else {
            lua_createtable(L, 0, 0)
            return 1
        }

        // Z-ordered (front to back) on-screen normal-layer windows.
        let cgList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        struct CGRow { let pid: pid_t; let bounds: CGRect; let z: Int }
        var cgRows: [CGRow] = []
        for w in cgList {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let bDict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bDict as CFDictionary)
            else { continue }
            cgRows.append(CGRow(pid: pid_t(pid), bounds: bounds, z: cgRows.count))
        }

        struct Row {
            let z: Int; let id: Int; let app: String; let title: String
            let bundleID: String; let screenName: String?; let iconToken: String
            let frame: CGRect
        }
        var rows: [Row] = []
        // Screen names only matter (and only render) on multi-display setups.
        let screens = NSScreen.screens
        let namedScreens: [(rect: CGRect, name: String)] = screens.count > 1
            ? screens.map { (axRect($0.frame), $0.localizedName) } : []
        var seenPids = Set<pid_t>()
        for pid in cgRows.map(\.pid) where !seenPids.contains(pid) {
            seenPids.insert(pid)
            guard let runApp = NSRunningApplication(processIdentifier: pid) else { continue }
            let appName = runApp.localizedName ?? "?"
            let bundleID = runApp.bundleIdentifier ?? ""

            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                kAXWindowsAttribute as CFString,
                                                &winsRef) == .success,
                  let axWins = winsRef as? [AXUIElement] else { continue }
            for win in axWins {
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
                guard (subroleRef as? String) == kAXStandardWindowSubrole as String else { continue }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                // Match this AX window to its CG z-position by frame (both are
                // top-left-origin screen coordinates; small tolerance for the
                // odd subpixel disagreement).
                var pos = CGPoint.zero, size = CGSize.zero
                if let v = axValue(win, kAXPositionAttribute as CFString) { AXValueGetValue(v, .cgPoint, &pos) }
                if let v = axValue(win, kAXSizeAttribute as CFString) { AXValueGetValue(v, .cgSize, &size) }
                let z = cgRows.first { r in
                    r.pid == pid
                        && abs(r.bounds.minX - pos.x) < 2 && abs(r.bounds.minY - pos.y) < 2
                        && abs(r.bounds.width - size.width) < 2
                        && abs(r.bounds.height - size.height) < 2
                }?.z ?? Int.max   // unmatched (e.g. minimized): list last

                let frame = CGRect(origin: pos, size: size)
                let screenName = namedScreens.first {
                    $0.rect.contains(CGPoint(x: frame.midX, y: frame.midY))
                }?.name

                let id = nextWindowId
                nextWindowId += 1
                axWindowCache[id] = win
                // Use bundleID for installed apps; fall back to pid for processes
                // without a .app bundle (e.g. the app itself under `swift run`).
                let iconToken = bundleID.isEmpty ? "appiconpid:\(pid)" : "appicon:\(bundleID)"
                rows.append(Row(z: z, id: id, app: appName,
                                title: title.isEmpty ? appName : title,
                                bundleID: bundleID, screenName: screenName,
                                iconToken: iconToken, frame: frame))
            }
        }
        rows.sort { $0.z < $1.z }

        lua_createtable(L, Int32(rows.count), 0)
        for (i, r) in rows.enumerated() {
            lua_createtable(L, 0, 10)
            lua_pushinteger(L, lua_Integer(r.id)); lua_setfield(L, -2, "id")
            lua_pushstring(L, r.title);            lua_setfield(L, -2, "title")
            lua_pushstring(L, r.app);              lua_setfield(L, -2, "appName")
            lua_pushstring(L, r.bundleID);         lua_setfield(L, -2, "bundleID")
            lua_pushstring(L, r.iconToken);        lua_setfield(L, -2, "icon")
            if let s = r.screenName {
                lua_pushstring(L, s);              lua_setfield(L, -2, "screenName")
            }
            // The window's frame (top-left-origin global points) -- lets the rules
            // engine snapshot the current arrangement ("Capture current layout").
            lua_pushnumber(L, r.frame.minX);   lua_setfield(L, -2, "x")
            lua_pushnumber(L, r.frame.minY);   lua_setfield(L, -2, "y")
            lua_pushnumber(L, r.frame.width);  lua_setfield(L, -2, "w")
            lua_pushnumber(L, r.frame.height); lua_setfield(L, -2, "h")
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    func axTrusted(_ L: OpaquePointer?) -> Int32 {
        lua_pushboolean(L, AXIsProcessTrusted() ? 1 : 0)
        return 1
    }

    // MARK: - Focused-window frame surface (window_snap)
    //
    // ONE coordinate system crosses the seam: top-left-origin global points
    // (what AX speaks). NSScreen frames are bottom-left-origin, so they are
    // converted here -- the Lua side never sees a flipped y.

    private func axRect(_ r: NSRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    private func focusedAXWindow() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(app.processIdentifier),
                kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // CoreFoundation types have no `as?` (the compiler rejects it and points
        // you at the CFTypeID compare we just did); the force-cast is the
        // canonical idiom and is safe here because the guard confirmed the type.
        return (ref as! AXUIElement)
    }

    private func axWindowFrame(_ win: AXUIElement) -> CGRect {
        var pos = CGPoint.zero, size = CGSize.zero
        if let v = axValue(win, kAXPositionAttribute as CFString) { AXValueGetValue(v, .cgPoint, &pos) }
        if let v = axValue(win, kAXSizeAttribute as CFString) { AXValueGetValue(v, .cgSize, &size) }
        return CGRect(origin: pos, size: size)
    }

    /// The AXValue of an AX attribute, or nil if the attribute is absent or not
    /// an AXValue -- so a malformed AX reply DEGRADES (caller keeps its default)
    /// rather than crashing. The `as!` is the canonical CoreFoundation cast (CF
    /// types have no `as?`; the CFTypeID guard above it IS the runtime type
    /// check). Confines that cast to one audited place; callers unwrap with the
    /// concrete .cgPoint/.cgSize kind they expect.
    private func axValue(_ element: AXUIElement, _ attr: CFString) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }

    private func pushRect(_ L: OpaquePointer?, _ r: CGRect) {
        lua_createtable(L, 0, 4)
        lua_pushnumber(L, r.minX);   lua_setfield(L, -2, "x")
        lua_pushnumber(L, r.minY);   lua_setfield(L, -2, "y")
        lua_pushnumber(L, r.width);  lua_setfield(L, -2, "w")
        lua_pushnumber(L, r.height); lua_setfield(L, -2, "h")
    }

    // focused_window_frame() -> nil | { x,y,w,h, fullscreen, screenIndex,
    // screen = {x,y,w,h} } -- screen is the window's screen's VISIBLE frame
    // (menubar/dock excluded, hs screen:frame() parity).
    func focusedWindowFrame(_ L: OpaquePointer?) -> Int32 {
        guard let win = focusedAXWindow() else {
            lua_pushnil(L)
            return 1
        }
        let frame = axWindowFrame(win)

        var fullscreen = false
        var fsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success {
            fullscreen = (fsRef as? Bool) ?? false
        }

        // The window's screen: the one containing its midpoint, else the first.
        let screens = NSScreen.screens
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        var screenIndex = 0
        for (i, s) in screens.enumerated() where axRect(s.frame).contains(mid) {
            screenIndex = i
            break
        }
        let visible = axRect(screens.isEmpty ? NSRect(x: 0, y: 0, width: 1440, height: 900)
                                             : screens[screenIndex].visibleFrame)

        pushRect(L, frame)
        lua_pushboolean(L, fullscreen ? 1 : 0); lua_setfield(L, -2, "fullscreen")
        lua_pushinteger(L, lua_Integer(screenIndex + 1)); lua_setfield(L, -2, "screenIndex")
        pushRect(L, visible); lua_setfield(L, -2, "screen")
        return 1
    }

    // focused_window_title() -> string|nil (needs Accessibility; nil without).
    // Cheap single-attribute read -- usage_stats derives the editor project
    // name from it.
    func focusedWindowTitle(_ L: OpaquePointer?) -> Int32 {
        guard let win = focusedAXWindow() else {
            lua_pushnil(L)
            return 1
        }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        if let title = titleRef as? String, !title.isEmpty {
            lua_pushstring(L, title)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    /// Set a window's frame with the size-position-size dance: apps clamp a frame
    /// against their CURRENT screen, so a cross-screen move applied as position-
    /// then-size (or size-then-position alone) can leave the size clamped to the
    /// OLD screen. The hs.window dance. Shared by the focused-window setter and the
    /// by-id setter (move-window-by-id, the window-layout engine).
    private func applyFrame(_ win: AXUIElement, x: Double, y: Double, w: Double, h: Double) -> Bool {
        var pos = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        guard let pv = AXValueCreate(.cgPoint, &pos), let sv = AXValueCreate(.cgSize, &size) else {
            return false
        }
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        let ok = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) == .success
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        return ok
    }

    // set_focused_window_frame(x, y, w, h) -> bool
    func setFocusedWindowFrame(_ L: OpaquePointer?) -> Int32 {
        guard let x = LuaState.double(L, 1), let y = LuaState.double(L, 2),
              let w = LuaState.double(L, 3), let h = LuaState.double(L, 4),
              let win = focusedAXWindow() else {
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, applyFrame(win, x: x, y: y, w: w, h: h) ? 1 : 0)
        return 1
    }

    // set_window_frame(id, x, y, w, h) -> bool -- move ANY window by an id from
    // the MOST RECENT list_windows() call (resolved via axWindowCache). The
    // window-layout engine lists, matches by app/title, then places each match.
    func setWindowFrame(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1),
              let x = LuaState.double(L, 2), let y = LuaState.double(L, 3),
              let w = LuaState.double(L, 4), let h = LuaState.double(L, 5),
              let win = axWindowCache[id] else {
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, applyFrame(win, x: x, y: y, w: w, h: h) ? 1 : 0)
        return 1
    }

    // set_focused_window_fullscreen(bool) -> bool
    func setFocusedWindowFullscreen(_ L: OpaquePointer?) -> Int32 {
        guard let win = focusedAXWindow() else {
            lua_pushboolean(L, 0)
            return 1
        }
        let on = LuaState.bool(L, 1)
        let ok = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString,
                                              (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        lua_pushboolean(L, ok == .success ? 1 : 0)
        return 1
    }

    // screen_frames() -> array of { x,y,w,h, name, index, builtin } visible frames
    // (top-left-origin), the order NSScreen.screens gives (primary first). The
    // name (localizedName, e.g. "Built-in Retina Display", "DELL U2720Q") is the
    // stable-ish key the window-layout engine targets a display by; `builtin`
    // (CGDisplayIsBuiltin) flags the laptop's own panel so "Capture current
    // layout" can keep just the EXTERNAL displays (the ones a connect rule is for).
    func screenFrames(_ L: OpaquePointer?) -> Int32 {
        let screens = NSScreen.screens
        lua_createtable(L, Int32(screens.count), 0)
        for (i, s) in screens.enumerated() {
            pushRect(L, axRect(s.visibleFrame))   // leaves a {x,y,w,h} table on top
            lua_pushstring(L, s.localizedName);       lua_setfield(L, -2, "name")
            lua_pushinteger(L, lua_Integer(i + 1));   lua_setfield(L, -2, "index")
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                       as? NSNumber)?.uint32Value ?? 0
            lua_pushboolean(L, CGDisplayIsBuiltin(num) != 0 ? 1 : 0)
            lua_setfield(L, -2, "builtin")
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    // mouse_position() -> {x, y} (top-left-origin, same space as frames).
    func mousePosition(_ L: OpaquePointer?) -> Int32 {
        let p = CGEvent(source: nil)?.location ?? .zero
        lua_createtable(L, 0, 2)
        lua_pushnumber(L, p.x); lua_setfield(L, -2, "x")
        lua_pushnumber(L, p.y); lua_setfield(L, -2, "y")
        return 1
    }

    func setMousePosition(_ L: OpaquePointer?) -> Int32 {
        guard let x = LuaState.double(L, 1), let y = LuaState.double(L, 2) else {
            return luaError(L, "set_mouse_position: x and y required")
        }
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        return 0
    }

    // Shows the system "wants to control this computer" prompt when untrusted
    // (the Accessibility onboarding hook for features that need windows).
    func axPrompt(_ L: OpaquePointer?) -> Int32 {
        // The literal key (== kAXTrustedCheckOptionPrompt, stable API contract);
        // the constant itself is a global var Swift 6 flags as concurrency-unsafe.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        lua_pushboolean(L, AXIsProcessTrustedWithOptions(opts) ? 1 : 0)
        return 1
    }
    func focusWindow(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1), let win = axWindowCache[id] else {
            lua_pushboolean(L, 0)
            return 1
        }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        var pid: pid_t = 0
        if AXUIElementGetPid(win, &pid) == .success {
            // Bringing the OWNING app frontmost. For our own process,
            // NSRunningApplication(self).activate() is a no-op from this
            // background / nonactivating-panel context (macOS cooperative
            // activation) -- self-activation must go through NSApp.activate,
            // the same path StatusBar uses to surface Settings. Other apps
            // are already raised by kAXRaiseAction; activate() finishes the
            // app switch for them.
            if pid == getpid() {
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
        lua_pushboolean(L, 1)
        return 1
    }
}
