// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Windows / apps via AXUIElement: listing, focus, frames, screens, mouse.

import AppKit
import CLua

extension Native {
    // MARK: - Windows / apps (AXUIElement)

    // list_windows() -> Lua window handles, MRU-first. The Lua side never sees
    // an AXUIElement: each call rebuilds `axWindowCache` (id -> {element, wid},
    // stored on the class -- see Native.swift) and focus_window(id) resolves from
    // it -- window_switcher always lists right before focusing, so a one-listing
    // cache is exactly the right lifetime.

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
        struct CGRow { let pid: pid_t; let wid: CGWindowID; let bounds: CGRect; let z: Int }
        var cgRows: [CGRow] = []
        for w in cgList {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let bDict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bDict as CFDictionary)
            else { continue }
            cgRows.append(CGRow(pid: pid_t(pid), wid: wid, bounds: bounds, z: cgRows.count))
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
                let cgMatch = cgRows.first { r in
                    r.pid == pid
                        && abs(r.bounds.minX - pos.x) < 2 && abs(r.bounds.minY - pos.y) < 2
                        && abs(r.bounds.width - size.width) < 2
                        && abs(r.bounds.height - size.height) < 2
                }
                let z = cgMatch?.z ?? Int.max   // unmatched (e.g. minimized): list last
                let wid = cgMatch?.wid ?? 0      // 0 -> focus targets the app, not this window

                let frame = CGRect(origin: pos, size: size)
                let screenName = namedScreens.first {
                    $0.rect.contains(CGPoint(x: frame.midX, y: frame.midY))
                }?.name

                let id = nextWindowId
                nextWindowId += 1
                axWindowCache[id] = AXWindowRef(element: win, wid: wid)
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

    /// The AXUIElement value of an AX attribute (e.g. AXMainWindow), or nil if it's
    /// absent / not an element. Sibling of axValue (which handles AXValue attrs);
    /// the `as!` is the canonical CF cast, gated by the CFTypeID check above it.
    private func axElementAttr(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
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
              let ref = axWindowCache[id] else {
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, applyFrame(ref.element, x: x, y: y, w: w, h: h) ? 1 : 0)
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

    // minimize_app(name) -> bool. Minimize the named app's front window (sets
    // AXMinimized). Pairs with a "Frontmost app leaves X" rule to hide a window
    // the moment focus moves away. The app is found by localizedName and targets
    // its main window (falling back to its focused / first standard window), so it
    // works even though the app is no longer frontmost. Needs Accessibility.
    func minimizeApp(_ L: OpaquePointer?) -> Int32 {
        guard let name = LuaState.string(L, 1) else {
            return luaError(L, "minimize_app: app name required")
        }
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })
        else {
            lua_pushboolean(L, 0)
            return 1
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let win = axElementAttr(appEl, kAXMainWindowAttribute as CFString)
            ?? axElementAttr(appEl, kAXFocusedWindowAttribute as CFString)
            ?? firstStandardWindow(appEl)
        guard let target = win else { lua_pushboolean(L, 0); return 1 }
        let ok = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString,
                                              kCFBooleanTrue as CFTypeRef)
        lua_pushboolean(L, ok == .success ? 1 : 0)
        return 1
    }

    // hide_app(name) -> bool. Hide the named app (the system Hide, like Cmd-H) --
    // all its windows vanish until reactivated. Sibling of minimize_app; uses the
    // public NSRunningApplication API, so (unlike minimize) it needs no Accessibility.
    func hideApp(_ L: OpaquePointer?) -> Int32 {
        guard let name = LuaState.string(L, 1) else {
            return luaError(L, "hide_app: app name required")
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })
        else { lua_pushboolean(L, 0); return 1 }
        lua_pushboolean(L, app.hide() ? 1 : 0)
        return 1
    }

    // quit_app(name) -> bool. Ask the named app to quit (a graceful terminate, like
    // Cmd-Q -- the app may still prompt to save). Returns whether the request was sent.
    func quitApp(_ L: OpaquePointer?) -> Int32 {
        guard let name = LuaState.string(L, 1) else {
            return luaError(L, "quit_app: app name required")
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })
        else { lua_pushboolean(L, 0); return 1 }
        lua_pushboolean(L, app.terminate() ? 1 : 0)
        return 1
    }

    // The first standard (titled) window of an app element, or its first window.
    private func firstStandardWindow(_ appEl: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return nil }
        for w in wins {
            var sub: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            if (sub as? String) == kAXStandardWindowSubrole as String { return w }
        }
        return wins.first
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

    // Opens System Settings straight to Privacy & Security -> Accessibility. The
    // system AXIsProcessTrustedWithOptions prompt appears only ONCE per app, so on
    // every later "Grant" click axPrompt shows nothing -- this navigates the user
    // to the exact pane regardless, the reliable "click -> land on the right
    // settings page" the system prompt alone can't guarantee.
    func openAccessibilitySettings(_ L: OpaquePointer?) -> Int32 {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return 0
    }

    func focusWindow(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1), let ref = axWindowCache[id] else {
            lua_pushboolean(L, 0)
            return 1
        }
        let win = ref.element
        var pid: pid_t = 0
        guard AXUIElementGetPid(win, &pid) == .success else {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            lua_pushboolean(L, 1)
            return 1
        }
        if pid == getpid() {
            // Our own (accessory) window: SLPS is for bringing OTHER apps
            // forward; self-activation goes through NSApp.activate, the same
            // path StatusBar uses to surface Settings.
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            NSApp.activate(ignoringOtherApps: true)
        } else if activateFrontProcess(pid: pid, wid: ref.wid) {
            // SLPS made the app frontmost and the window key; the raise just
            // orders it to the top of its app's own window stack (belt-and-
            // suspenders for apps that key a window without front-ordering it).
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        } else {
            // SLPS unavailable (private symbol moved): fall back to the AX +
            // cooperative-activate path -- still works, just less reliably
            // across apps from our non-active accessory context.
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        lua_pushboolean(L, 1)
        return 1
    }

    // MARK: - Reliable cross-app activation (SkyLight SLPS)
    //
    // NSRunningApplication.activate() is *cooperative* on macOS 14+: the system
    // honors "bring app B forward" only from the currently-active app (or one it
    // yields to). We are an .accessory app showing a .nonactivatingPanel, so we
    // are NEVER the active app -- which made focus_window / activate_app raise a
    // window inside its app yet intermittently fail to front the app itself
    // (it worked only when the target app already happened to be frontmost).
    // AltTab / yabai / the Hammerspoon #370 thread all converge on the SkyLight
    // SLPS front-process API, which is not gated by cooperative activation.
    // Resolved via dlsym (no private-framework link flag), and with a
    // hand-rolled PSN struct + dlsym'd GetProcessForPID so we reference no
    // deprecated Carbon symbols.

    /// Bring `pid`'s app frontmost and -- when `wid != 0` -- make that exact
    /// window key, bypassing cooperative activation. Returns false (so the caller
    /// can fall back) only if the private SLPS symbols can't be resolved.
    @discardableResult
    func activateFrontProcess(pid: pid_t, wid: CGWindowID = 0) -> Bool {
        guard let getPSN = SLPS.getProcessForPID, let setFront = SLPS.setFrontProcess else {
            return false
        }
        var psn = SLPSProcessSerial()
        guard getPSN(pid, &psn) == 0 else { return false }
        withUnsafeMutableBytes(of: &psn) { p in
            _ = setFront(p.baseAddress!, wid, SLPS.userGenerated)
        }
        if wid != 0, let post = SLPS.postEvent {
            makeKeyWindow(&psn, wid: wid, post: post)
        }
        return true
    }

    // The two-event SLPS dance that makes window `wid` the key window of its
    // process (ported faithfully from the Hammerspoon #370 / yabai recipe; the
    // magic byte offsets are an undocumented SLPS event record).
    private func makeKeyWindow(_ psn: inout SLPSProcessSerial, wid: CGWindowID,
                               post: SLPS.PostEventFn) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x01
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: wid) { src in
            for i in 0..<4 { bytes[0x3c + i] = src[i] }
        }
        for i in 0..<0x10 { bytes[0x20 + i] = 0xff }
        withUnsafeMutableBytes(of: &psn) { psnPtr in
            bytes.withUnsafeMutableBytes { _ = post(psnPtr.baseAddress!, $0.baseAddress!) }
            bytes[0x08] = 0x02
            bytes.withUnsafeMutableBytes { _ = post(psnPtr.baseAddress!, $0.baseAddress!) }
        }
    }
}

// A private ProcessSerialNumber stand-in: reimplemented so the SLPS plumbing
// touches no deprecated Carbon types (the real PSN struct is deprecated too).
private struct SLPSProcessSerial { var hi: UInt32 = 0; var lo: UInt32 = 0 }

// dlsym-resolved private SkyLight + Carbon entry points. Lazy statics -> resolved
// once, thread-safely. nil if a symbol ever disappears (callers fall back).
private enum SLPS {
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Int32
    typealias PostEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32

    static let userGenerated: UInt32 = 0x200   // kCPSUserGenerated

    static let getProcessForPID: GetProcessForPIDFn? = sym("GetProcessForPID")
    static let setFrontProcess: SetFrontFn? = sym("_SLPSSetFrontProcessWithOptions")
    static let postEvent: PostEventFn? = sym("SLPSPostEventRecordTo")

    // The SLPS symbols live in SkyLight; GetProcessForPID lives in
    // ApplicationServices (and is `unavailable` to Swift, hence dlsym). dlopen
    // both so resolution never hinges on AppKit's framework load order, with
    // RTLD_DEFAULT (-2) as a final catch-all for anything already mapped. Read
    // once, never mutated -> the unchecked annotation is sound.
    nonisolated(unsafe) private static let handles: [UnsafeMutableRawPointer?] = [
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
        UnsafeMutableRawPointer(bitPattern: -2),
    ]

    private static func sym<T>(_ name: String) -> T? {
        for h in handles {
            if let h, let p = dlsym(h, name) { return unsafeBitCast(p, to: T.self) }
        }
        return nil
    }
}
