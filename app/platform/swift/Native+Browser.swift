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

    // launch_or_focus_app(bundleId): focus the app, LAUNCHING it first if it is
    // not running (unlike activate_app, which only focuses a running app). Keyed
    // by bundle identifier -- stable across languages, and the only id that
    // resolves to a launchable URL. Returns false only when no installed app
    // carries that bundle id. The launch is async; callers settle before typing.
    func launchOrFocusApp(_ L: OpaquePointer?) -> Int32 {
        guard let bundleId = LuaState.string(L, 1),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            lua_pushboolean(L, 0)
            return 1
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        lua_pushboolean(L, 1)
        return 1
    }

    private func escAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // Snapshot all Chrome tab URLs, then raise + activate the first window whose
    // tab URL contains `pattern`. When none matches and `openFallback` is set,
    // open it as a new tab. Returns whether a match was found, or nil on script
    // error (Chrome missing / Automation denied). The donor's "snapshot then act
    // by index" shape -- mutating window order while iterating live lists
    // misbehaves. CURATED template: features never run arbitrary osascript.
    // An app-mode window is just a Chrome window with one tab, so this raises
    // those too. Shared by focus_browser_tab and open_site_app.
    private func chromeFocusTab(matching pattern: String, openFallback: String?) -> Bool? {
        let fallbackClause = openFallback.map {
            "tell application \"Google Chrome\" to make new tab at window 1 with properties {URL:\"\(escAppleScript($0))\"}"
        } ?? ""
        let script = """
        activate application "Google Chrome"
        tell application "Google Chrome" to set windowTabList to URL of tabs of every window
        set found to false
        set windowIndex to 1
        repeat with thisWindowsTabs in windowTabList
            set tabIndex to 1
            repeat with tabURL in thisWindowsTabs
                if tabURL as text contains "\(escAppleScript(pattern))" then
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
            \(fallbackClause)
        end if
        return found
        """
        return runFoundScript(script)
    }

    // Run a curated focus-or-open AppleScript ending in `return found`. Returns
    // the boolean, or nil on a script error (browser missing / Automation
    // denied) -- callers degrade nil to "not found".
    private func runFoundScript(_ script: String) -> Bool? {
        var errInfo: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errInfo)
        if let errInfo {
            print("[hammerdeck] focus tab failed: "
                + ((errInfo[NSAppleScript.errorMessage] as? String) ?? "\(errInfo)"))
            return nil
        }
        return result?.booleanValue == true
    }

    // Safari analog of chromeFocusTab: focus the first Safari tab whose URL
    // contains `pattern`, else open `openFallback` (Safari's dialect differs --
    // `current tab` / `tabs of window` / `open location`; a tab's URL can be
    // `missing value`, which must be guarded before coercion). Curated template.
    private func safariFocusTab(matching pattern: String, openFallback: String?) -> Bool? {
        let fallbackClause = openFallback.map { "open location \"\(escAppleScript($0))\"" } ?? ""
        let script = """
        tell application "Safari"
            activate
            set found to false
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u is not missing value and (u as text) contains "\(escAppleScript(pattern))" then
                        set current tab of w to t
                        set index of w to 1
                        set found to true
                        exit repeat
                    end if
                end repeat
                if found then exit repeat
            end repeat
            if not found then
                \(fallbackClause)
            end if
            return found
        end tell
        """
        return runFoundScript(script)
    }

    // focus_browser_tab(pattern, fallbackURL) -> found. Brings the first
    // Chrome tab whose URL contains `pattern` to front; opens fallbackURL in a
    // new tab when absent (the donor miscBindings "locate otter" flow,
    // parameterized). First use triggers the macOS Automation permission prompt
    // ("control Google Chrome").
    func focusBrowserTab(_ L: OpaquePointer?) -> Int32 {
        guard let pattern = LuaState.string(L, 1), let fallback = LuaState.string(L, 2) else {
            return luaError(L, "focus_browser_tab: pattern and fallbackURL required")
        }
        // nil (script error) degrades to "not found" -- the caller logged why.
        let found = chromeFocusTab(matching: pattern, openFallback: fallback) ?? false
        lua_pushboolean(L, found ? 1 : 0)
        return 1
    }

    // focus_safari_tab(pattern, fallbackURL) -> found. The Safari counterpart of
    // focus_browser_tab, so a Safari-routed Quick Site focuses its open tab
    // instead of always opening a new one. First use triggers the Automation
    // prompt ("control Safari").
    func focusSafariTab(_ L: OpaquePointer?) -> Int32 {
        guard let pattern = LuaState.string(L, 1), let fallback = LuaState.string(L, 2) else {
            return luaError(L, "focus_safari_tab: pattern and fallbackURL required")
        }
        let found = safariFocusTab(matching: pattern, openFallback: fallback) ?? false
        lua_pushboolean(L, found ? 1 : 0)
        return 1
    }

    // Launch a Chromium browser's executable with `args`, logging a failure
    // instead of swallowing it. Afterward raises an already-running instance (the
    // bare exe hand-off opens the window but may not front it; a fresh launch
    // fronts itself). Returns whether the launch was dispatched.
    @discardableResult
    private func launchChromium(_ exe: URL, bundleId: String, args: [String]) -> Bool {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        do {
            try p.run()
        } catch {
            print("[hammerdeck] open_site: launch failed for \(bundleId): \(error)")
            return false
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        if #available(macOS 14.0, *) { running?.activate() } else { running?.activate(options: []) }
        return true
    }

    // open_site_app(pattern, url) -> found. Like focus_browser_tab, but when no
    // existing Chrome tab/window matches, it opens the site as a CHROMELESS
    // CHROME APP WINDOW (`chrome --app=<url>`) instead of a normal tab -- the
    // "site as a standalone app" flow. An already-open app window is just a
    // Chrome window, so the shared snapshot raises it. Chrome-only; callers gate
    // on default_browser_bundle_id and fall back to a tab otherwise.
    func openSiteApp(_ L: OpaquePointer?) -> Int32 {
        guard let pattern = LuaState.string(L, 1), let url = LuaState.string(L, 2) else {
            return luaError(L, "open_site_app: pattern and url required")
        }
        if chromeFocusTab(matching: pattern, openFallback: nil) == true {
            lua_pushboolean(L, 1)
            return 1
        }
        // No existing window (or script error): launch a fresh app-mode window.
        // Invoke Chrome's executable directly -- `open --args` is ignored once
        // Chrome is already running, but the binary hands --app to that instance.
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
           let exe = Bundle(url: appURL)?.executableURL {
            launchChromium(exe, bundleId: "com.google.Chrome", args: ["--app=\(url)"])
        }
        lua_pushboolean(L, 0)
        return 1
    }

    // open_site(bundleId, profile, app, url) -> launched. Open `url` in a
    // SPECIFIC browser. For a Chromium browser this launches its executable with
    // `--profile-directory=<profile>` (when set) and either `--app=<url>` (a
    // chromeless app window) or `<url>` (a tab) -- the only reliable way to
    // target a profile / app window. For a non-Chromium browser (Safari,
    // Firefox) it opens the URL as a plain tab; profile/app don't apply.
    func openSite(_ L: OpaquePointer?) -> Int32 {
        guard let bundleId = LuaState.string(L, 1), let url = LuaState.string(L, 4) else {
            return luaError(L, "open_site: bundleId and url required")
        }
        let profile = LuaState.string(L, 2) ?? ""
        let app = LuaState.bool(L, 3)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            print("[hammerdeck] open_site: no app for bundle id \(bundleId)")
            lua_pushboolean(L, 0)
            return 1
        }
        if BrowserCatalog.isChromium(bundleId), let exe = Bundle(url: appURL)?.executableURL {
            var args: [String] = []
            if !profile.isEmpty { args.append("--profile-directory=\(profile)") }
            if app {
                args.append("--app=\(url)")          // `=`-bound: cannot introduce a new switch
            } else {
                // `--` ends switch parsing, so a URL that happens to start with
                // `-` can't be read as a Chrome flag (e.g. --disable-web-security).
                args.append("--")
                args.append(url)
            }
            lua_pushboolean(L, launchChromium(exe, bundleId: bundleId, args: args) ? 1 : 0)
            return 1
        }
        if let u = URL(string: url) {
            // Non-Chromium: open the URL in that browser (profile/app ignored).
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([u], withApplicationAt: appURL, configuration: cfg, completionHandler: nil)
            lua_pushboolean(L, 1)
            return 1
        }
        lua_pushboolean(L, 0)
        return 1
    }

    // default_browser_bundle_id() -> bundleId|nil. The app macOS would use to
    // open an https URL right now (the user's default browser). Lets a feature
    // gate browser-specific behavior on the user's chosen browser.
    func defaultBrowserBundleId(_ L: OpaquePointer?) -> Int32 {
        if let u = URL(string: "https://example.com"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: u),
           let id = Bundle(url: appURL)?.bundleIdentifier {
            lua_pushstring(L, id)
        } else {
            lua_pushnil(L)
        }
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
