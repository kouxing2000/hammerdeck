// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Windows / apps via AXUIElement: listing, focus, frames, screens, mouse.

import AppKit
import CLua

// The donor's identity primitive (Hammerspoon HSuicore.m:657): the private AX
// call `_AXUIElementGetWindow` resolves an AXUIElement DIRECTLY to its stable
// CGWindowID -- exact even for minimized or mid-flight windows, where the
// public CG-bounds matching below can fail. Private API, so it is looked up
// via dlsym rather than linked: if a future macOS removes the symbol, the
// lookup returns nil and everything degrades to the public bounds-match
// fallback instead of failing at load. (Owner-approved hybrid, 2026-07-01.)
private let axUIElementGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
    guard let sym = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
}()

/// The stable CGWindowID for an AX window via the private call; 0 when the
/// symbol is unavailable or the element can't be resolved (callers fall back
/// to CG bounds-matching, then to title-based identity in Lua).
func axStableWindowID(_ element: AXUIElement) -> CGWindowID {
    guard let fn = axUIElementGetWindow else { return 0 }
    var wid: CGWindowID = 0
    guard fn(element, &wid) == .success else { return 0 }
    return wid
}

/// The running application that owns `pid`. `NSRunningApplication(processIdentifier:)`
/// alone is not enough: it can answer nil for EVERY app at once, for one call, while
/// `NSWorkspace.shared.runningApplications` still lists them all (measured in a VM:
/// 7 of 219 window listings), so a caller that gives up on nil loses real apps.
func runningApplication(pid: pid_t) -> NSRunningApplication? {
    NSRunningApplication(processIdentifier: pid)
        ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
}

extension Native {
    // MARK: - AX messaging timeout

    /// Every AX read in this file is a SYNCHRONOUS cross-process call on the main
    /// thread, and the ceiling applies PER attribute read. listWindows does
    /// several reads per window across every app, so unresponsive apps stack those
    /// into a freeze: that is the inner half of the 2026-07-23 hang, where
    /// window_fan's 2s poll ran an AX enumeration inside a blocked AppleScript's
    /// nested event loop.
    ///
    /// One call on the SYSTEM-WIDE element sets the default for the whole process
    /// (per AXUIElement.h: "Pass the system-wide accessibility object if you want
    /// to set the timeout globally for this process"), so every element created
    /// later inherits it -- no per-element bookkeeping, and no way for a new AX
    /// caller to miss it. Called once from installBindings, before any Lua runs.
    ///
    /// THE VALUE IS MEASURED, NOT GUESSED -- and the measurement is the whole
    /// point, because the platform default is far TIGHTER than it looks. Probing
    /// `kAXWindows` across every regular app on this machine (alternating configs,
    /// resetting via the documented `0` = restore-default):
    ///
    ///     default   slowest read 1.505-1.515s   (3 runs, tightly clustered)
    ///     2.0s      slowest read 2.008s         <- ABOVE the default: loosens it
    ///     0.3s      slowest read 0.305s
    ///
    /// So the default is ~1.5s, and an earlier 2.0s here made the bound WORSE
    /// while slowing every listWindows pass. 0.3s is what bounds a full pass:
    /// with several wedged apps, 0.3s each keeps a pass near a second instead of
    /// the ~7s the default allows -- and window_fan polls every 2s.
    /// If you change this number, RE-MEASURE; do not trust the header's silence
    /// about the default.
    ///
    /// AN EARLIER VERSION OF THIS COMMENT CLAIMED 0.3s "cost zero successes".
    /// That was WRONG, and the error was expensive (2026-07-25): a re-measure
    /// across every app owning an on-screen window found 0.3s dropping NINE of
    /// 23 apps, where 1.0s dropped five and 2.0s four. The cost is not per-call,
    /// it is a ONE-TIME COLD HANDSHAKE -- five consecutive full passes, same
    /// 0.3s ceiling, once the connections were warm:
    ///
    ///     pass 1  0.527s      pass 2  0.010s      pass 3  0.010s
    ///     pass 4  0.013s      pass 5  0.016s
    ///
    /// A cold app therefore needs far MORE than 0.3s exactly once and ~0.5ms
    /// forever after -- so a fixed 0.3s ceiling can never pay the handshake, the
    /// app fails, stays cold, and fails again on every listing. That is a TRAP,
    /// not a timeout: those nine apps' windows were missing from every listing
    /// for HOURS (they simply never appear -- see the throttled log line in
    /// listWindows), which left window_fan blind to a third of the machine's
    /// windows and unable to ever highlight a focused window living in one.
    ///
    /// The fix is NOT a bigger number here -- that would put the cold cost
    /// (9 apps x 1s) straight onto the main thread, which is the freeze 0.3s
    /// exists to prevent. It is `warmAXConnection` below: pay the handshake
    /// ONCE, OFF the main thread, and let the steady-state ceiling stay tight.
    static func applyAXMessagingTimeout() {
        let err = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        if err != .success {
            // Silent failure here would leave every AX call on the loose default
            // with nothing to show for it.
            Native.shared.seamLog("AX messaging timeout not applied (AXError \(err.rawValue))")
        }
    }

    /// Pay a cold app's one-time AX handshake on a BACKGROUND queue, so the next
    /// main-thread listing finds it warm and answers inside the 0.3s ceiling.
    ///
    /// Called only from listWindows' `.cannotComplete` branch -- i.e. an app that
    /// just missed the ceiling. Without this the miss is PERMANENT (see the
    /// measurement in applyAXMessagingTimeout): the app is cold, 0.3s is not
    /// enough to warm it, and nothing else ever gives it longer.
    ///
    /// Why a background queue is safe here, and why it is the whole point: the AX
    /// *client* attribute-read API is callable off the main thread (only the
    /// observer callbacks need a run loop, and those stay on main -- see
    /// FocusObserver / FrameObserverSet). The element is created on that queue and
    /// never escapes it, so nothing is shared. The generous per-element timeout is
    /// set on THAT element only -- never via the system-wide element, which would
    /// change the process-global default and quietly loosen every main-thread read.
    ///
    /// The result is DISCARDED: this exists only for its side effect of completing
    /// the handshake. Warming is also shared between AX clients (proven: an
    /// external probe warming these apps made a running Hammerdeck see them
    /// immediately), so the work is never wasted even if the app is listed by
    /// something else first.
    /// `ceiling` is the per-element budget for the one cold read; it is a parameter
    /// only so a test can drive the whole path without paying the real 5s.
    /// Production callers take the default.
    func warmAXConnection(pid: pid_t, appName: String, ceiling: Float = 5) {
        // ONE guard, deliberately: the 30s rate limit also covers "a warm-up is
        // already in flight", because the ceiling is far below it -- no attempt can
        // still be running when the window reopens. An in-flight Set alongside this
        // was redundant state whose only job was to be released, and forgetting to
        // release it would have silently disabled warming for that app forever.
        // window_fan lists several times per focus event, so the limit is what stops
        // the warm-ups from becoming the storm they exist to prevent.
        if let last = axWarmAttemptedAt[pid], Date().timeIntervalSince(last) < 30 { return }
        axWarmAttemptedAt[pid] = Date()
        // A SERIAL queue, not the global concurrent pool. The motivating case is a
        // cold boot where NINE apps miss the ceiling in the same listing, and each
        // warm-up is a BLOCKING cross-process read that can sit for the whole
        // ceiling -- dispatching those concurrently is the classic thread-explosion
        // shape for blocking IPC. Serialized, the worst case is one wedged app
        // delaying another app's warm-up by a few seconds, which costs nothing: the
        // next listing retries, and nobody is waiting on the result.
        Native.axWarmQueue.async {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, ceiling)
            var ref: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(
                element, kAXWindowsAttribute as CFString, &ref)
            let ok = err == .success && (ref as? [AXUIElement]) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Throttled by app, like the miss itself: a chronically dead
                    // app would otherwise write a line every 30s. The SUCCESS
                    // line is the one worth having -- it is the evidence that a
                    // missing app has come back, and it should appear once.
                    if ok {
                        Native.shared.seamLog(
                            "list_windows: '\(appName)' warmed up off the main thread -- "
                            + "its windows will appear from the next listing")
                    } else {
                        // Interpolate the real ceiling: it is a parameter, and a log
                        // line that states a number the run did not use is worse than
                        // no number at all.
                        Native.shared.seamLogThrottled(
                            "axwarm:" + appName,
                            "list_windows: '\(appName)' did not answer even with a "
                            + "\(ceiling)s background warm-up (AXError \(err.rawValue)) "
                            + "-- it is wedged, not merely cold; its windows stay missing")
                    }
                }
            }
        }
    }

    // MARK: - Windows / apps (AXUIElement)

    // list_windows() -> Lua window handles, MRU-first. The Lua side never sees
    // an AXUIElement: each call refreshes `axWindowCache` (id -> {element, wid},
    // stored on the class -- see Native.swift) and focus_window(id) resolves from
    // it. A window KEEPS its id across listings (keyed by the stable CGWindowID),
    // so a handle a feature holds across a chooser session stays valid even when
    // another feature (window_fan) re-lists in between -- see the rebuild in
    // listWindows for why the naive one-listing cache was a switch-window bug.

    /// Real window enumeration: AXUIElement per app for titles + elements
    /// (Accessibility permission only -- no Screen Recording, which CGWindowList
    /// window NAMES would require), z-ordered via CGWindowList bounds matching
    /// (front-to-back ~= focus recency, the same ordering hs.window.orderedWindows
    /// gives the donor). Returns {} when the permission is missing -- features
    /// check ax_trusted/ax_prompt to onboard.
    func listWindows(_ L: OpaquePointer?) -> Int32 {
        // Rebuilt by every listing (including the untrusted early-out), so
        // windows_dropped_apps() always describes the listing just returned.
        lastListingDroppedApps = []
        guard AXIsProcessTrusted() else {
            axWindowCache.removeAll()
            lua_createtable(L, 0, 0)
            return 1
        }
        // A window keeps the SAME id across listings (keyed by its stable
        // CGWindowID), so a handle a feature is HOLDING survives an intervening
        // list_windows from ANOTHER feature. window_switcher / tab_switcher list,
        // show a chooser, then focus on the user's pick many seconds later --
        // meanwhile window_fan (Window Fan) re-lists on every poll / activation.
        // The old removeAll() + fresh-id-per-listing silently invalidated those
        // held handles, so focus_window(id) resolved nothing and no-oped (the
        // "can't switch windows" bug -- worse when cycling deep for a same-app
        // window, which keeps the chooser open longer). Only a genuinely new or
        // wid-unresolved window draws a fresh id. (Tradeoff: macOS may RECYCLE a
        // CGWindowID after a window closes, so in the sub-second between a
        // listing and a pick a held id could in theory rebind to a different
        // window that reused the wid -- vanishingly rare, and strictly better
        // than the old guaranteed no-op.)
        var widToId: [CGWindowID: Int] = [:]
        for (id, ref) in axWindowCache where ref.wid != 0 { widToId[ref.wid] = id }
        var freshCache: [Int: AXWindowRef] = [:]

        // Z-ordered (front to back) on-screen normal-layer windows.
        let cgList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        struct CGRow { let pid: pid_t; let wid: CGWindowID; let bounds: CGRect; let z: Int
                       let owner: String }
        var cgRows: [CGRow] = []
        for w in cgList {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let bDict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bDict as CFDictionary)
            else { continue }
            cgRows.append(CGRow(pid: pid_t(pid), wid: wid, bounds: bounds, z: cgRows.count,
                                owner: (w[kCGWindowOwnerName as String] as? String) ?? "?"))
        }

        struct Row {
            let z: Int; let id: Int; let wid: CGWindowID; let app: String
            let title: String; let bundleID: String; let screenName: String?
            let iconToken: String; let frame: CGRect; let tabCount: Int?
            let minimized: Bool; let fullscreen: Bool
        }
        var rows: [Row] = []
        // Screen names only matter (and only render) on multi-display setups.
        let screens = NSScreen.screens
        let namedScreens: [(rect: CGRect, name: String)] = screens.count > 1
            ? screens.map { (axRect($0.frame), $0.localizedName) } : []
        var seenPids = Set<pid_t>()
        // One read per listing, looked up per pid below.
        let appsByPid = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for pid in cgRows.map(\.pid) where !seenPids.contains(pid) {
            seenPids.insert(pid)
            // Identity from the listing's own snapshot of NSWorkspace, never a bare
            // NSRunningApplication(processIdentifier:) -- see runningApplication(pid:).
            // An app with no record still has its windows listed: AX needs only the
            // pid, and skipping the app would empty the listing whenever the lookup
            // fails.
            let runApp = appsByPid[pid] ?? NSRunningApplication(processIdentifier: pid)
            let appName = runApp?.localizedName
                ?? cgRows.first { $0.pid == pid }?.owner ?? "?"
            let bundleID = runApp?.bundleIdentifier ?? ""
            if runApp == nil {
                seamLogThrottled("appmeta:\(appName)",
                                 "list_windows: no running-app record for pid \(pid) ('\(appName)') "
                                 + "-- its windows are listed without a bundle id")
            }

            var winsRef: CFTypeRef?
            let winsErr = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                        kAXWindowsAttribute as CFString,
                                                        &winsRef)
            guard winsErr == .success, let axWins = winsRef as? [AXUIElement] else {
                // An app that misses the AX ceiling has ALL its windows dropped
                // from this listing -- the user just sees them missing from the
                // switcher. Say so, or that is a silent hole. Throttled per app:
                // window_fan re-lists every 2s, and a chronically slow app would
                // otherwise write a line per poll.
                // Report the hole for ANY failure, not just a timeout: whatever the
                // reason, this app's windows are absent from the listing, and a
                // caller tracking windows across listings must be able to tell "this
                // app went quiet" from "these windows closed". Narrowing this to
                // .cannotComplete would silently skip the reservation for every other
                // error.
                if !bundleID.isEmpty { lastListingDroppedApps.append(bundleID) }
                if winsErr == .cannotComplete {
                    seamLogThrottled("axwins:" + appName,
                                     "list_windows: '\(appName)' did not answer within the AX "
                                     + "timeout -- its windows are missing from this listing")
                    // A miss is usually a COLD app, not a wedged one, and at 0.3s
                    // it can never warm itself -- so pay the handshake off the main
                    // thread and let the next listing find it. Without this the
                    // app's windows stay missing indefinitely (see warmAXConnection).
                    warmAXConnection(pid: pid, appName: appName)
                }
                continue
            }
            for win in axWins {
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
                guard (subroleRef as? String) == kAXStandardWindowSubrole as String else { continue }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                // Visibility state: callers that lay windows out (Window Deck)
                // must be able to exclude minimized/fullscreen windows -- the
                // AX enumeration returns them with their normal frames.
                var minRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef)
                let minimized = (minRef as? Bool) ?? false
                var fsRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef)
                let fullscreen = (fsRef as? Bool) ?? false

                var pos = CGPoint.zero, size = CGSize.zero
                if let v = axValue(win, kAXPositionAttribute as CFString) { AXValueGetValue(v, .cgPoint, &pos) }
                if let v = axValue(win, kAXSizeAttribute as CFString) { AXValueGetValue(v, .cgSize, &size) }
                // Match this AX window to its CG row (z-position + stable wid).
                // Primary: the exact CGWindowID from the private call (see
                // axStableWindowID). Fallback: match by frame (both top-left-
                // origin; small tolerance for subpixel disagreement) -- which
                // can miss for minimized or mid-move windows.
                let exactWid = axStableWindowID(win)
                let cgMatch = exactWid != 0
                    ? cgRows.first { $0.wid == exactWid }
                    : cgRows.first { r in
                        r.pid == pid
                            && abs(r.bounds.minX - pos.x) < 2 && abs(r.bounds.minY - pos.y) < 2
                            && abs(r.bounds.width - size.width) < 2
                            && abs(r.bounds.height - size.height) < 2
                    }
                let z = cgMatch?.z ?? Int.max   // unmatched (e.g. minimized): list last
                let wid = exactWid != 0 ? exactWid : (cgMatch?.wid ?? 0)   // 0 -> unresolved

                let frame = CGRect(origin: pos, size: size)
                let screenName = namedScreens.first {
                    $0.rect.contains(CGPoint(x: frame.midX, y: frame.midY))
                }?.name

                let id: Int
                if wid != 0, let existing = widToId[wid] {
                    id = existing            // stable window -> keep held handles valid
                } else {
                    id = nextWindowId
                    nextWindowId += 1
                }
                freshCache[id] = AXWindowRef(element: win, wid: wid)
                // Use bundleID for installed apps; fall back to pid for processes
                // without a .app bundle (e.g. the app itself under `swift run`).
                let iconToken = bundleID.isEmpty ? "appiconpid:\(pid)" : "appicon:\(bundleID)"
                // Tab count, browser windows only (gated so a non-browser app's
                // AXTabGroup never yields a misleading badge); nil otherwise.
                let tabCount = Self.browserBundleIDs.contains(bundleID)
                    ? browserTabCount(win) : nil
                rows.append(Row(z: z, id: id, wid: wid, app: appName,
                                title: title.isEmpty ? appName : title,
                                bundleID: bundleID, screenName: screenName,
                                iconToken: iconToken, frame: frame, tabCount: tabCount,
                                minimized: minimized, fullscreen: fullscreen))
            }
        }
        // Swap in the rebuilt cache atomically: entries for windows that closed
        // since the last listing drop out; still-present windows kept their id.
        axWindowCache = freshCache
        rows.sort { $0.z < $1.z }

        lua_createtable(L, Int32(rows.count), 0)
        for (i, r) in rows.enumerated() {
            lua_createtable(L, 0, 14)
            lua_pushinteger(L, lua_Integer(r.id)); lua_setfield(L, -2, "id")
            lua_pushboolean(L, r.minimized ? 1 : 0);  lua_setfield(L, -2, "minimized")
            lua_pushboolean(L, r.fullscreen ? 1 : 0); lua_setfield(L, -2, "fullscreen")
            // The OS-stable CGWindowID (0 = unresolved): survives retitles, so
            // callers key long-lived identity on it (Window Deck's members).
            lua_pushinteger(L, lua_Integer(r.wid)); lua_setfield(L, -2, "wid")
            lua_pushstring(L, r.title);            lua_setfield(L, -2, "title")
            lua_pushstring(L, r.app);              lua_setfield(L, -2, "appName")
            lua_pushstring(L, r.bundleID);         lua_setfield(L, -2, "bundleID")
            lua_pushstring(L, r.iconToken);        lua_setfield(L, -2, "icon")
            if let s = r.screenName {
                lua_pushstring(L, s);              lua_setfield(L, -2, "screenName")
            }
            if let n = r.tabCount {
                lua_pushinteger(L, lua_Integer(n)); lua_setfield(L, -2, "tabCount")
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

    /// windows_dropped_apps() -> { bundleID, ... } for the MOST RECENT
    /// list_windows: the apps whose windows are missing from it because they did
    /// not answer AX in time. Empty on a clean listing.
    ///
    /// This exists because absence from a window listing is AMBIGUOUS -- a window
    /// that closed and a window whose app went quiet look identical -- and a caller
    /// that guesses can do real damage: window_fan freed the captured pre-fan frame
    /// of any window missing from a listing, so one AX hiccup permanently lost the
    /// user's real window geometry (2026-07-25). The seam is the only layer that
    /// knows which it was, so it says.
    func windowsDroppedApps(_ L: OpaquePointer?) -> Int32 {
        lua_createtable(L, Int32(lastListingDroppedApps.count), 0)
        for (i, id) in lastListingDroppedApps.enumerated() {
            lua_pushstring(L, id)
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

    private func axRole(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    /// Bundle IDs whose standard windows host a countable tab strip. Gated so a
    /// non-browser app that happens to use an AXTabGroup never gets a misleading
    /// "N tabs" badge in the switcher (the count heuristic is browser-shaped).
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    /// Tab count for a browser window: the AXGroup/AXRadioButton children of the
    /// first AXTabGroup in the window's subtree (the lone trailing AXButton "+"
    /// is excluded by role). nil when no tab strip is found (row shows no badge).
    /// Bounded BFS: the tab strip lives ~6 levels down in the browser chrome, so
    /// a small node budget plus pruning of rendered web content (AXWebArea /
    /// AXScrollArea -- the page DOM is thousands of nodes) keeps this cheap and
    /// guarantees we never walk into the page.
    private func browserTabCount(_ win: AXUIElement) -> Int? {
        var frontier: [(AXUIElement, Int)] = [(win, 0)]
        // Worst-case bound on blocking main-thread AX IPC for a browser window
        // with NO tab strip (a PWA / app-shell / popup, which still carries a
        // browser bundle ID): such a window otherwise walks the whole tree.
        // A real strip is found within a few dozen nodes, well under this.
        var budget = 200
        while !frontier.isEmpty, budget > 0 {
            budget -= 1
            let (node, depth) = frontier.removeFirst()
            let role = axRole(node)
            if role == "AXTabGroup" {
                let n = axChildren(node).filter {
                    let r = axRole($0); return r == "AXGroup" || r == "AXRadioButton"
                }.count
                return n > 0 ? n : nil
            }
            if depth < 8, role != "AXWebArea", role != "AXScrollArea" {
                for k in axChildren(node) { frontier.append((k, depth + 1)) }
            }
        }
        return nil
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
        let sizeErr = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        let posErr = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        // The caller only hears false, and "refused" has several causes -- a timeout
        // (-25204), an invalid element (-25202), an app that rejects the write. The
        // codes are the difference. A size error alone is routine (fixed-size windows
        // such as Calculator refuse it) and is not a failure.
        if posErr != .success {
            seamLogThrottled("applyFrame:\(posErr.rawValue)",
                             "set frame refused: position AXError \(posErr.rawValue), "
                             + "size AXError \(sizeErr.rawValue), target \(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))")
        }
        return posErr == .success
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

    // set_window_frame(id, x, y, w, h) -> bool -- move ANY window by an id from a
    // list_windows() call (resolved via axWindowCache). Not only the most recent
    // one: a window with a RESOLVED wid keeps its id for as long as it keeps
    // APPEARING in listings, so a held id stays good across an intervening list by
    // another feature. Two ways it stops: the window drops out of a listing
    // (closed, or its app missed the AX ceiling) and comes back with a NEW id; or
    // its wid never resolved at all (`wid == 0`), in which case `widToId` cannot
    // key it and it is re-minted on EVERY listing while still present. The
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
        let on = LuaState.bool(L, 1) ?? false
        let ok = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString,
                                              (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        lua_pushboolean(L, ok == .success ? 1 : 0)
        return 1
    }

    // Find a RUNNING app by its bundle identifier OR its localized name. The rules
    // editor stores a bundle id (stable across locale + app rename -- the canonical
    // key, matching how launchOrFocusApp resolves apps), but legacy rules and the
    // "@trigger:app" sentinel still pass a display name, so we accept either: bundle
    // id first, name as the fallback. No activationPolicy filter -- a target named
    // explicitly is honored even if it's an agent/accessory app.
    private func runningApp(matching target: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        return apps.first(where: { $0.bundleIdentifier == target })
            ?? apps.first(where: { $0.localizedName == target })
    }

    // minimize_app(app) -> bool. Minimize the app's front window (sets AXMinimized).
    // Pairs with a "Frontmost app leaves X" rule to hide a window the moment focus
    // moves away. `app` is a bundle id or localized name (see runningApp); targets
    // its main window (falling back to its focused / first standard window), so it
    // works even though the app is no longer frontmost. Needs Accessibility.
    func minimizeApp(_ L: OpaquePointer?) -> Int32 {
        guard let target = LuaState.string(L, 1) else {
            return luaError(L, "minimize_app: app required")
        }
        guard AXIsProcessTrusted(), let app = runningApp(matching: target)
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

    // hide_app(app) -> bool. Hide the app (the system Hide, like Cmd-H) -- all its
    // windows vanish until reactivated. `app` is a bundle id or localized name (see
    // runningApp). Sibling of minimize_app; uses the public NSRunningApplication
    // API, so (unlike minimize) it needs no Accessibility.
    func hideApp(_ L: OpaquePointer?) -> Int32 {
        guard let target = LuaState.string(L, 1) else {
            return luaError(L, "hide_app: app required")
        }
        guard let app = runningApp(matching: target)
        else { lua_pushboolean(L, 0); return 1 }
        lua_pushboolean(L, app.hide() ? 1 : 0)
        return 1
    }

    // quit_app(app) -> bool. Ask the app to quit (a graceful terminate, like Cmd-Q
    // -- the app may still prompt to save). `app` is a bundle id or localized name
    // (see runningApp). Returns whether the request was sent.
    func quitApp(_ L: OpaquePointer?) -> Int32 {
        guard let target = LuaState.string(L, 1) else {
            return luaError(L, "quit_app: app required")
        }
        guard let app = runningApp(matching: target)
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

    // screen_frames() -> array of { x,y,w,h, name, index, builtin, full } visible frames
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
            // ...plus the FULL frame, because the row answers two different
            // questions. Placement wants the visible frame (never put a window
            // under the menu bar). MEMBERSHIP -- "which display is this window
            // ON" -- wants the full one, or the menu-bar and Dock strips read as
            // belonging to no display at all, and `listWindows` disagrees on the
            // same window in the same breath: its `namedScreens` map builds each
            // window's `screenName` from axRect($0.frame), not the visible one.
            pushRect(L, axRect(s.frame));             lua_setfield(L, -2, "full")
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

    // Raise a listed window above others via a window-level AXRaise. For most
    // apps this is surgical (2026-07-01 z-order probe): it does NOT drag the
    // app's same-app sibling windows forward (same-screen OR cross-screen) and
    // does NOT steal app activation, so it can't trip the focus observer / cause
    // a spurious promotion, and it can't beat the currently-active window. BUT
    // some apps (VSCode, Chrome) ACTIVATE the window they are asked to raise, so
    // on those an AXRaise DOES front the app -- which is why Window Deck raises
    // its non-hero members with this but reclaims the HERO's top slot with
    // focus_window (a real SLPS activation that beats an activating member),
    // NOT another surgical raise. Id from the most recent listWindows(); returns
    // true on success.
    func raiseWindow(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1), let ref = axWindowCache[id] else {
            lua_pushboolean(L, 0); return 1
        }
        let ok = AXUIElementPerformAction(ref.element, kAXRaiseAction as CFString) == .success
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
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
            runningApplication(pid: pid)?.activate()
        }
        lua_pushboolean(L, 1)
        return 1
    }

    // on_focused_window_changed(fn): fn() (a bare pulse, no args) fires whenever
    // the frontmost app's focused window changes -- the within-app switch (cmd+`)
    // that on_app_activated (app-level) cannot see. The observer re-targets to the
    // newly-frontmost app on each activation, so a caller subscribing to BOTH
    // sees every focus move. Needs Accessibility (AXObserver). Window Deck uses it
    // to drive focus-driven hero promotion.
    func onFocusedWindowChanged(_ L: OpaquePointer?) -> Int32 {
        let ref = lua.makeRef(at: 1)
        let obs = FocusObserver(ref: ref)
        let id = registerResource { MainActor.assumeIsolated { obs.stop() } }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // focused_window_wid() -> the FOCUSED window's stable CGWindowID (0 =
    // unresolvable). Primary: the same private call the listing uses; fallback:
    // CFEqual against the last listing's cached AX elements (AX elements
    // compare reliably with CFEqual -- it is hs.window's __eq). Lets callers
    // match "who is focused" against wid-keyed identity without titles.
    func focusedWindowWid(_ L: OpaquePointer?) -> Int32 {
        guard let win = focusedAXWindow() else {
            lua_pushinteger(L, 0)
            return 1
        }
        var wid = axStableWindowID(win)
        if wid == 0 {
            for (_, ref) in axWindowCache where CFEqual(ref.element, win) {
                wid = ref.wid
                break
            }
        }
        lua_pushinteger(L, lua_Integer(wid))
        return 1
    }

    // on_window_frames_changed(bundleIds, fn): fn({bundleID, title, wid, x, y, w, h})
    // fires whenever a window of one of the given apps moves or resizes -- the
    // frame in top-left global points (the seam's one coordinate system).
    // Fires for OUR OWN AX moves too; callers guard their own echoes. Window
    // Deck uses it to hide a member's ring while the user drags/resizes the
    // window, re-showing it at the real frame once stable.
    func onWindowFramesChanged(_ L: OpaquePointer?) -> Int32 {
        let bundleIDs = LuaState.stringArray(L, 1)
        let ref = lua.makeRef(at: 2)
        let obs = FrameObserverSet(bundleIDs: bundleIDs, ref: ref)
        let id = registerResource { MainActor.assumeIsolated { obs.stop() } }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

}

/// Watches `kAXFocusedWindowChangedNotification` on the frontmost app, swapping
/// the AXObserver to whichever app becomes frontmost (an app's observer only sees
/// ITS OWN focus changes). Fires a bare Lua pulse on each change; the caller
/// re-lists to learn who is focused now. All on main (AX run-loop source on the
/// main loop, NSWorkspace queue = .main) -- matching Native's whole-app invariant.
@MainActor
final class FocusObserver {
    private let ref: Int32
    private var axObserver: AXObserver?
    private var observedPid: pid_t = 0
    private var activationToken: NSObjectProtocol?

    init(ref: Int32) {
        self.ref = ref
        let center = NSWorkspace.shared.notificationCenter
        activationToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.retarget(to: app) }
        }
        retarget(to: NSWorkspace.shared.frontmostApplication)
    }

    // Point the AX observer at `app`'s focused-window-changed notification,
    // tearing down any previous one. No-op if it is already watching this pid.
    private func retarget(to app: NSRunningApplication?) {
        let pid = app?.processIdentifier ?? 0
        if pid == observedPid, axObserver != nil { return }
        teardownAX()
        guard let app, pid > 0, !app.isTerminated else { return }
        // A non-capturing C callback: route back to `self` via the refcon.
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.fire() }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl,
                                  kAXFocusedWindowChangedNotification as CFString, refcon)
        // .commonModes, not .defaultMode: menu tracking and modal panels run the
        // main loop in their OWN mode, and a source registered only in the default
        // mode is not served there. Focus changes arriving while a menu is open
        // are then never delivered at all -- not queued -- so Window Deck misses
        // the promotion outright and resumes on stale state. Every other run-loop
        // source in the seam (Native+Triggers, CapsHyperTap) is already common.
        //
        // The trade, stated because it IS a trade: this also widens Lua
        // re-entrancy into those loops -- a focus handler can now run AX moves
        // while the user holds a menu open. Every seam timer already fires in
        // .common, so the delta is one more source rather than a new hazard, and
        // a handler that misses the event entirely is the worse failure. If a
        // future handler must not run mid-menu, gate it on the mode; do not send
        // this source back to .defaultMode, which fixes nothing and re-deafens
        // the observer.
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(obs), .commonModes)
        axObserver = obs
        observedPid = pid
    }

    private func teardownAX() {
        if let obs = axObserver {
            // Must name the SAME mode the add used, or the source is never removed.
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs), .commonModes)
            // No explicit destroy: dropping the last reference tears the observer
            // (and its remaining notification registrations) down.
        }
        axObserver = nil
        observedPid = 0
    }

    private func fire() {
        Native.shared.lua.callRef(ref) { _ in 0 }   // bare pulse, zero args
    }

    func stop() {
        if let token = activationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            activationToken = nil
        }
        teardownAX()
        Native.shared.lua.releaseRef(ref)
    }
}

/// Watches `kAXWindowMovedNotification` + `kAXWindowResizedNotification` on a
/// FIXED set of apps (e.g. the deck's member apps) and fires a Lua callback
/// with the moved window's identity and real frame. Unlike FocusObserver
/// (frontmost app only, retargeting), this holds one AXObserver per app for
/// the subscription's whole lifetime -- a background window can move too. The
/// app-level registration also covers windows the app creates later. All on
/// main (AX run-loop source on the main loop) -- Native's whole-app invariant.
/// ACCEPTED LIMITATION (owner call, 2026-07-01): attaches only to apps alive
/// at subscribe time and does not re-attach if a member app quits and
/// relaunches mid-subscription -- by then its windows are NEW windows (a deck
/// marks the old member gone), so move/resize tracking for the relaunched app
/// is simply absent until the next subscription. AXObserverAddNotification
/// results are likewise unchecked; a failed attach degrades the same way.
@MainActor
final class FrameObserverSet {
    private let ref: Int32
    private var observers: [AXObserver] = []

    init(bundleIDs: [String], ref: Int32) {
        self.ref = ref
        let wanted = Set(bundleIDs)
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier.map(wanted.contains) == true && !app.isTerminated {
            attach(app.processIdentifier)
        }
    }

    private func attach(_ pid: pid_t) {
        guard pid > 0 else { return }
        // A non-capturing C callback: route back to `self` via the refcon.
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FrameObserverSet>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.fire(element) }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appEl, kAXWindowResizedNotification as CFString, refcon)
        // .commonModes for the same reason as the focus observer above: a window
        // dragged while a menu or modal panel is up must still report its move.
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(obs), .commonModes)
        observers.append(obs)
    }

    // The callback's element IS the moved window: read its identity + frame
    // (AX position/size are already top-left global points) and hand them to
    // Lua as one info table.
    private func fire(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let bundleID = runningApplication(pid: pid)?.bundleIdentifier ?? ""
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""
        var pos = CGPoint.zero, size = CGSize.zero
        if let v = Self.axValue(element, kAXPositionAttribute as CFString) {
            AXValueGetValue(v, .cgPoint, &pos)
        }
        if let v = Self.axValue(element, kAXSizeAttribute as CFString) {
            AXValueGetValue(v, .cgSize, &size)
        }
        let wid = axStableWindowID(element)   // 0 when unresolvable -> title fallback
        Native.shared.lua.callRef(ref) { L in
            lua_createtable(L, 0, 7)
            lua_pushstring(L, bundleID);    lua_setfield(L, -2, "bundleID")
            lua_pushstring(L, title);       lua_setfield(L, -2, "title")
            lua_pushinteger(L, lua_Integer(wid)); lua_setfield(L, -2, "wid")
            lua_pushnumber(L, pos.x);       lua_setfield(L, -2, "x")
            lua_pushnumber(L, pos.y);       lua_setfield(L, -2, "y")
            lua_pushnumber(L, size.width);  lua_setfield(L, -2, "w")
            lua_pushnumber(L, size.height); lua_setfield(L, -2, "h")
            return 1
        }
    }

    private static func axValue(_ element: AXUIElement, _ attr: CFString) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }

    func stop() {
        for obs in observers {
            // Must name the SAME mode the add used, or the source is never removed.
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observers.removeAll()
        Native.shared.lua.releaseRef(ref)
    }
}
