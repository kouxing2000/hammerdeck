// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Apps / URLs + browser tabs (curated JXA templates).

import AppKit
import CLua

extension Native {
    // MARK: - Apps / URLs

    func openUrl(_ L: OpaquePointer?) -> Int32 {
        guard let s = LuaState.string(L, 1), let url = URL(string: s) else {
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, NSWorkspace.shared.open(url) ? 1 : 0)
        return 1
    }

    // activate_app(name): bring a RUNNING app (by localized name) frontmost.
    // Returns false when it is not running (donor semantics -- no launching).
    func activateApp(_ L: OpaquePointer?) -> Int32 {
        guard let name = LuaState.string(L, 1) else {
            lua_pushboolean(L, 0)
            return 1
        }
        if let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.localizedName == name }) {
            app.activate()
            lua_pushboolean(L, 1)
        } else {
            lua_pushboolean(L, 0)
        }
        return 1
    }

    // focus_browser_tab(pattern, fallbackURL) -> found. Brings the first
    // Chrome tab whose URL contains `pattern` to front; opens fallbackURL in a
    // new tab when absent (the donor miscBindings "locate otter" flow,
    // parameterized). CURATED AppleScript: the script is a fixed template in
    // the seam -- features never run arbitrary osascript. First use triggers
    // the macOS Automation permission prompt ("control Google Chrome").
    func focusBrowserTab(_ L: OpaquePointer?) -> Int32 {
        guard let pattern = LuaState.string(L, 1), let fallback = LuaState.string(L, 2) else {
            return luaError(L, "focus_browser_tab: pattern and fallbackURL required")
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        // The donor's script shape: snapshot all tab URLs first, then act by
        // indices (mutating window order while iterating live lists misbehaves).
        let script = """
        activate application "Google Chrome"
        tell application "Google Chrome" to set windowTabList to URL of tabs of every window
        set found to false
        set windowIndex to 1
        repeat with thisWindowsTabs in windowTabList
            set tabIndex to 1
            repeat with tabURL in thisWindowsTabs
                if tabURL as text contains "\(esc(pattern))" then
                    tell application "Google Chrome"
                        set index of window windowIndex to 1
                        set active tab index of window 1 to tabIndex
                    end tell
                    set found to true
                    exit repeat
                end if
                set tabIndex to tabIndex + 1
            end repeat
            if found then exit repeat
            set windowIndex to windowIndex + 1
        end repeat
        if not found then
            tell application "Google Chrome" to make new tab at window 1 with properties {URL:"\(esc(fallback))"}
        end if
        return found
        """
        var errInfo: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errInfo)
        if let errInfo {
            // Chrome missing / Automation permission denied: degrade, log why.
            print("[hammerdeck] focus_browser_tab failed: "
                + ((errInfo[NSAppleScript.errorMessage] as? String) ?? "\(errInfo)"))
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, result?.booleanValue == true ? 1 : 0)
        return 1
    }

    // MARK: - Browser tabs (curated JXA templates -- tab_switcher)
    //
    // Only these two browsers are scriptable here; the app-name argument is
    // validated against this whitelist before it goes anywhere near a script.
    private static let scriptableBrowsers: Set<String> = ["Google Chrome", "Safari"]

    func appRunning(_ L: OpaquePointer?) -> Int32 {
        let name = LuaState.string(L, 1)
        let running = name != nil && NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == name
        }
        lua_pushboolean(L, running ? 1 : 0)
        return 1
    }

    // Run a fixed JXA template asynchronously via osascript; cb(stdout|nil).
    // Out-of-process like the donor's hs.task -- a slow browser cannot hang
    // the host. The script TEXT is never caller-supplied.
    private func runJXA(_ script: String, _ ref: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.terminationHandler = { proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = proc.terminationStatus == 0
                ? String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        if let text { lua_pushstring(L, text) } else { lua_pushnil(L) }
                        return 1
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }
        do { try p.run() } catch {
            lua.callRef(ref) { L in lua_pushnil(L); return 1 }
            lua.releaseRef(ref)
        }
    }

    // browser_list_tabs(app, cb): cb gets a JSON string
    // {"tabs":[{title,url,winId,tabIndex,visible}...]} or nil. JSON is built
    // with JSON.stringify (the donor hand-concatenated and broke on quotes).
    func browserListTabs(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app) else {
            return luaError(L, "browser_list_tabs: unsupported app")
        }
        let ref = lua.makeRef(at: 2)
        let script = """
        function run() {
          var app = Application("\(app)");
          var out = [];
          var wins = app.windows();
          for (var wi = 0; wi < wins.length; wi++) {
            var win = wins[wi];
            var winId = 0, visible = true, name = "";
            try { winId = win.id(); } catch (e) {}
            try { visible = win.visible(); } catch (e) {}
            try { name = win.name() || ""; } catch (e) {}
            if (!name || name.length === 0) { visible = false; }
            var tabs = [];
            try { tabs = win.tabs(); } catch (e) {}
            for (var ti = 0; ti < tabs.length; ti++) {
              var tab = tabs[ti], title = "", url = "";
              try { title = ("\(app)" === "Safari") ? tab.name() : tab.title(); } catch (e) {}
              try { url = tab.url() || ""; } catch (e) {}
              out.push({ title: title || "", url: url, winId: winId,
                         tabIndex: ti + 1, visible: visible });
            }
          }
          return JSON.stringify({ tabs: out });
        }
        """
        runJXA(script, ref)
        return 0
    }

    // browser_focus_tab_at(app, winId, tabIndex, cb): raises the window, makes
    // the tab active; cb gets {"url": "..."} JSON (the tab's CURRENT url, which
    // may have drifted since listing) or nil.
    func browserFocusTabAt(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app),
              let winId = LuaState.int(L, 2), let tabIndex = LuaState.int(L, 3) else {
            return luaError(L, "browser_focus_tab_at: unsupported app or bad indices")
        }
        let ref = lua.makeRef(at: 4)
        let script = """
        function run() {
          var app = Application("\(app)");
          app.activate();
          var wins = app.windows();
          for (var wi = 0; wi < wins.length; wi++) {
            var win = wins[wi];
            var id = -1;
            try { id = win.id(); } catch (e) {}
            if (id === \(winId)) {
              win.index = 1;
              var tabs = win.tabs();
              if (\(tabIndex) >= 1 && \(tabIndex) <= tabs.length) {
                var tab = tabs[\(tabIndex) - 1];
                if ("\(app)" === "Safari") { win.currentTab = tab; }
                else { win.activeTabIndex = \(tabIndex); }
                var url = "";
                try { url = tab.url() || ""; } catch (e) {}
                return JSON.stringify({ url: url });
              }
            }
          }
          return JSON.stringify({});
        }
        """
        runJXA(script, ref)
        return 0
    }

    // browser_active_url(app) -> url|nil. Sync + cheap (one property read);
    // this is the curated "what is the browser looking at" call (#9 context).
    func browserActiveUrl(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app) else {
            lua_pushnil(L)
            return 1
        }
        let source = app == "Safari"
            ? "tell application \"Safari\" to return URL of front document"
            : "tell application \"Google Chrome\" to return URL of active tab of front window"
        var errInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errInfo)
        if errInfo == nil, let url = result?.stringValue, !url.isEmpty {
            lua_pushstring(L, url)
        } else {
            lua_pushnil(L)
        }
        return 1
    }
}
