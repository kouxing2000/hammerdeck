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
            // SLPS front-process (reliable from our non-active accessory; see
            // Native+Windows), falling back to cooperative activate() if the
            // private API is unavailable.
            if !activateFrontProcess(pid: app.processIdentifier) { app.activate() }
            lua_pushboolean(L, 1)
        } else {
            lua_pushboolean(L, 0)
        }
        return 1
    }

    // launch_or_focus_app(bundleId, cb?) -> ok, id?: focus the app, LAUNCHING it
    // first if it is not running (unlike activate_app, which only focuses a
    // running app). Keyed by bundle identifier -- stable across languages.
    // `ok` is false when the app cannot be launched as far as anyone can tell up
    // front. The launch itself is async and macOS can still refuse it; the
    // refusal's reason goes to the daily log always, and to cb(false, reason)
    // when a callback is passed (cb(true) on success) -- a cancelable one-shot
    // whose id is the 2nd return.
    //
    // WITH a callback, resolution falls back to the same disk scan app_launcher
    // lists from: LaunchServices answers nil for an app it has registered but
    // will not run (an Xcode flagged version-too-low for this macOS), and asking
    // it to open the bundle is the only way to get its reason. WITHOUT one the
    // caller acts on `ok` alone, and must keep hearing false for such an app --
    // text_actions would otherwise type a paste + Return into whatever app is
    // frontmost, and a rule would log a refused launch as fired.
    func launchOrFocusApp(_ L: OpaquePointer?) -> Int32 {
        guard let bundleId = LuaState.string(L, 1) else {
            lua_pushboolean(L, 0)
            return 1
        }
        let ref = lua.makeCallbackRef(at: 2, named: "launch_or_focus_app")
        let onDisk = { Self.scanInstalledApps().first(where: { $0.bundleId == bundleId })
                           .map { URL(fileURLWithPath: $0.path) } }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                ?? (ref == LUA_REFNIL ? nil : onDisk()) else {
            if ref != LUA_REFNIL { lua.releaseRef(ref) }
            lua_pushboolean(L, 0)
            return 1
        }
        let id: Int32? = ref == LUA_REFNIL ? nil : allocOneShot()
        if let id { armOneShot(id, ref) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            let reason = error.map { Self.launchFailureReason($0) }
            if let error {
                let chain = Self.errorChain(error)
                    .map { "\($0.domain) \($0.code): \($0.localizedDescription)" }
                    .joined(separator: " <- ")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Native.shared.seamLog("launch \(bundleId) (\(url.path)) failed -- \(chain)")
                    }
                }
            }
            guard let id else { return }
            Native.fireOneShot(id, ref) { L in
                lua_pushboolean(L, reason == nil ? 1 : 0)
                if let reason { lua_pushstring(L, reason) } else { lua_pushnil(L) }
                return 2
            }
        }
        lua_pushboolean(L, 1)
        guard let id else { return 1 }
        lua_pushinteger(L, lua_Integer(id))
        return 2
    }

    /// An error followed down its NSUnderlyingError links, outermost first.
    nonisolated static func errorChain(_ error: Error) -> [NSError] {
        var chain = [error as NSError]
        while chain.count < 8,
              let next = chain[chain.count - 1].userInfo[NSUnderlyingErrorKey] as? NSError {
            chain.append(next)
        }
        return chain
    }

    /// The user-facing reason a launch failed. NSWorkspace wraps a LaunchServices
    /// refusal in a generic NSCocoaErrorDomain 256 ("a miscellaneous error
    /// occurred"), so descend past those wrappers -- and only those: any other
    /// outer error already says what happened in its own words. LaunchServices'
    /// OSStatus text is prefixed with its constant ("kLSIncompatibleApplication
    /// VersionErr: The app is incompatible with the current OS") -- the prefix
    /// goes, the sentence stays.
    nonisolated static func launchFailureReason(_ error: Error) -> String {
        let chain = errorChain(error)
        let named = chain.first { !($0.domain == NSCocoaErrorDomain && $0.code == 256) }
        let text = (named ?? chain[chain.count - 1]).localizedDescription
        guard let prefix = text.range(of: #"^kLS\w+:\s*"#, options: .regularExpression)
        else { return text }
        return String(text[prefix.upperBound...])
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
        return runFoundScript(script, "Google Chrome")
    }

    // Run a curated focus-or-open AppleScript ending in `return found`. Returns
    // the boolean, or nil on a script error (browser missing / Automation
    // denied) -- callers degrade nil to "not found".
    //
    // Deliberately NOT liveness-gated (`requiring:` unset): these scripts open a
    // site, so launching a cold browser IS the requested behavior.
    //
    // 8s, not longer: this blocks the main thread, and the incident it guards
    // against was 25s -- a 20s beachball would be barely an improvement. 8s
    // covers a warm browser's tab scan comfortably; a cold browser degrades to
    // "not found" (the caller's existing nil path) instead of freezing the app.
    //
    // UNVERIFIED EDGE, do not assume otherwise: `with timeout` is confirmed to
    // bound an Apple Event SEND, but it was NOT confirmed to bound the LAUNCH
    // these scripts can trigger (`activate application ...` on a cold browser),
    // nor a first-run Automation consent dialog. If either turns out to be
    // unbounded, this path can still stall -- it is manual-trigger only (a
    // deliberate hotkey), so nothing fires it unattended, but the honest fix
    // would be moving it to the async out-of-process shape rather than raising
    // the ceiling.
    private func runFoundScript(_ script: String, _ browser: String) -> Bool? {
        // Label carries the browser so a failure line says WHICH one failed --
        // and so the per-label throttle cannot let Safari's error mask Chrome's.
        guard let result = runAppleScript(script, timeout: 8,
                                          label: "focus tab (\(browser))") else {
            return nil   // script error OR timeout -- both mean "could not tell"
        }
        return result.booleanValue == true
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
        return runFoundScript(script, "Safari")
    }

    // focus_browser_tab(pattern, fallbackURL) -> found. Brings the first
    // Chrome tab whose URL contains `pattern` to front; opens fallbackURL in a
    // new tab when absent (the donor config's locate-a-site flow, parameterized).
    // First use triggers the macOS Automation permission prompt
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
            // seamLog, not print: this sits on the private-open failure path, and
            // app.sh redirects stdout, which is then BLOCK-buffered -- a print here
            // would simply never appear (the trap CLAUDE.md documents).
            seamLog("open_site: launch failed for \(bundleId): \(error)")
            return false
        }
        // SLPS front-process (reliable from our non-active accessory; see
        // Native+Windows), falling back to cooperative activate().
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        if let pid = running?.processIdentifier, activateFrontProcess(pid: pid) {
            // fronted via SLPS
        } else if #available(macOS 14.0, *) {
            running?.activate()
        } else {
            running?.activate(options: [])
        }
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

    // open_site(bundleId, profile, app, url, incognito) -> launched. Open `url` in
    // a SPECIFIC browser. For a Chromium browser this launches its executable with
    // `--profile-directory=<profile>` (when set), `--incognito` (when asked) and
    // either `--app=<url>` (a chromeless app window) or `<url>` (a tab) -- the only
    // reliable way to target a profile / app window. For a non-Chromium browser
    // (Safari, Firefox) it opens the URL as a plain tab; profile/app don't apply.
    //
    // ONE RULE ABOUT `incognito`, so a window can never LOOK private while being
    // recorded -- plus one measured fact that used to be a second rule:
    //   * A browser not VERIFIED to honor `--incognito` REFUSES (returns false)
    //     instead of opening a normal window -- see BrowserCatalog's
    //     privateWindowBundleIds for why membership is narrower than "is Chromium".
    //     The honest answer is "I can't", not a window the caller will describe to
    //     the user as private.
    //   * `--incognito` COMPOSES with app mode -- MEASURED, not assumed. Chrome's
    //     own UI offers no incognito app window, so this first shipped forcing the
    //     pair apart on the theory that an app window might quietly persist the
    //     visit. A probe settled it (2026-07-30): launched with both switches in
    //     the order below, Chrome opens a window that is chromeless AND private --
    //     confirmed by eye, and by its absence from browser_list_tabs while an
    //     otherwise identical `--app=` window IS enumerated. Deciding it instead of
    //     measuring it cost the user a real combination, so: if you change this
    //     ordering, re-run that probe rather than reasoning about it.
    // The refusal lives in `openSite`; the argv rules live in `chromiumArgs`, which
    // is pure and unit-tested -- they carry the guarantee, so they must not be a
    // detail buried in a bridge function no test can reach.
    func openSite(_ L: OpaquePointer?) -> Int32 {
        guard let bundleId = LuaState.string(L, 1), let url = LuaState.string(L, 4) else {
            return luaError(L, "open_site: bundleId and url required")
        }
        let profile = LuaState.string(L, 2) ?? ""
        let app = LuaState.bool(L, 3) ?? false
        let incognito = LuaState.bool(L, 5) ?? false
        // Refuse BEFORE resolving the app: a private open the seam cannot honor
        // must fail the same way whether the browser is missing or merely unvouched.
        if incognito && !BrowserCatalog.supportsPrivateWindow(bundleId) {
            seamLog("open_site: refusing a private open for '\(bundleId)' -- not a browser "
                    + "verified to honor --incognito")
            lua_pushboolean(L, 0)
            return 1
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            seamLog("open_site: no app for bundle id '\(bundleId)'")
            lua_pushboolean(L, 0)
            return 1
        }
        if BrowserCatalog.isChromium(bundleId), let exe = Bundle(url: appURL)?.executableURL {
            let args = Self.chromiumArgs(profile: profile, app: app, incognito: incognito, url: url)
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

    /// The Chromium launch switches for one site open. PURE (no OS calls) so the
    /// rule the private-window promise rests on is unit-testable: `--incognito` is
    /// actually in the vector, alongside whatever else was asked for. The caller has
    /// already refused an unvouched browser -- this only builds the argv.
    /// `nonisolated` because it genuinely is: no shared state, no OS call. Without
    /// it the function inherits Native's @MainActor and a test cannot call it.
    /// The switch ORDER here is the one the probe in the note above exercised.
    nonisolated static func chromiumArgs(profile: String, app: Bool, incognito: Bool,
                                         url: String) -> [String] {
        var args: [String] = []
        if !profile.isEmpty { args.append("--profile-directory=\(profile)") }
        if incognito { args.append("--incognito") }
        if app {
            args.append("--app=\(url)")              // `=`-bound: cannot introduce a new switch
        } else {
            // `--` ends switch parsing, so a URL that happens to start with `-`
            // can't be read as a Chrome flag (e.g. --disable-web-security).
            args.append("--")
            args.append(url)
        }
        return args
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
        // Same predicate the AppleScript chokepoint's `requiring:` gate uses --
        // shared so the Lua-visible answer and the seam's own decision can never
        // drift apart.
        let running = LuaState.string(L, 1).map(Native.appIsRunning(named:)) ?? false
        lua_pushboolean(L, running ? 1 : 0)
        return 1
    }

    private static let jxaTimeoutSeconds: TimeInterval = 30  // survive most first-run TCC prompts

    // Run a fixed JXA template asynchronously via osascript; cb(stdout|nil), with
    // nil for a non-zero exit or a launch that failed. Out-of-process like the
    // donor's hs.task -- a slow browser cannot hang the host. The script TEXT is
    // never caller-supplied.
    //
    // The subprocess mechanics -- concurrent pipe drains, the exactly-once
    // completion, the pipe retention that fixed the dropped-callback bug, the
    // SIGTERM watchdog -- all live in runProcessCore (Native+Process.swift),
    // shared with the `exec` capability's run_process. Reading stdout only AFTER
    // termination deadlocks once osascript's output exceeds the ~64KB pipe buffer
    // (hundreds of tabs), which is why that core drains as it goes. The tab list
    // must arrive whole, so this caller takes the default UNCAPPED stdout.
    @discardableResult
    private func runJXACore(_ script: String,
                            _ completion: @escaping @Sendable (String?) -> Void)
    -> (@Sendable () -> Void)? {
        runProcessCore(executable: "/usr/bin/osascript",
                       args: ["-l", "JavaScript", "-e", script],
                       timeout: Native.jxaTimeoutSeconds,
                       label: "jxa",
                       // stderr is read only to keep a chatty child from wedging on a
                       // full pipe, and then discarded -- so cap what is retained.
                       stderrCap: 64 * 1024) { status, out, _ in
            guard status == 0 else { completion(nil); return }
            completion(String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // Lua-facing wrapper: run the template, then fire the pinned Lua callback (once).
    // Returns the cancelable-one-shot resource id so the caller can hand it to Lua --
    // a feature disabled while osascript is still running must not receive the tabs.
    // Teardown SIGTERMs the osascript rather than only dropping the callback: a
    // tab read abandoned by a disabled feature has no reason to keep a process
    // alive for the rest of its 30s ceiling.
    private func runJXA(_ script: String, _ ref: Int32) -> Int32 {
        let id = allocOneShot()
        let terminate = runJXACore(script) { text in
            Native.fireOneShot(id, ref) { L in
                if let text { lua_pushstring(L, text) } else { lua_pushnil(L) }
                return 1
            }
        }
        armOneShot(id, ref) { terminate?() }
        return id
    }

    #if DEBUG
    // Test seam (no browser, no TCC): drive runJXACore with a controlled-size stdout
    // payload to prove a >64KB result does not deadlock the pipe. The caller supplies
    // only a byte COUNT -- the script text is fixed here, never caller-controlled.
    func runJXASelfTest(bytes: Int, _ completion: @escaping @Sendable (Int?) -> Void) {
        runJXACore("function run(){ return Array(\(bytes + 1)).join('x'); }") { completion($0?.count) }
    }
    #endif

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
            // Chrome's JXA returns window/tab ids as STRINGS -- normalize to numbers
            // so the JSON carries numeric ids (Lua integers) and focus can compare
            // them numerically. Chrome ids are well under 2^53, so no precision loss.
            try { winId = Number(win.id()) || 0; } catch (e) {}
            try { visible = win.visible(); } catch (e) {}
            try { name = win.name() || ""; } catch (e) {}
            if (!name || name.length === 0) { visible = false; }
            // PRIVACY: never enumerate incognito Chrome tabs (mirrors the guard in
            // browser_active_url). Safari exposes no per-window private flag, so it
            // cannot be filtered here -- documented as a best-effort gap.
            var mode = ""; try { mode = win.mode(); } catch (e) {}
            if (mode === "incognito") { continue; }
            var tabs = [];
            try { tabs = win.tabs(); } catch (e) {}
            for (var ti = 0; ti < tabs.length; ti++) {
              var tab = tabs[ti], title = "", url = "", tid = 0;
              try { title = ("\(app)" === "Safari") ? tab.name() : tab.title(); } catch (e) {}
              try { url = tab.url() || ""; } catch (e) {}
              // Chrome tabs carry a stable id (survives reorder/close/move); Safari
              // tabs have none, so tab.id() throws and id stays 0 (-> url fallback).
              // Chrome returns it as a STRING -> Number() (see winId note above).
              try { tid = Number(tab.id()) || 0; } catch (e) {}
              out.push({ title: title || "", url: url, winId: winId,
                         tabIndex: ti + 1, id: tid, visible: visible });
            }
          }
          return JSON.stringify({ tabs: out });
        }
        """
        lua_pushinteger(L, lua_Integer(runJXA(script, ref)))
        return 1
    }

    // A safe JS string literal (quotes + escaping) for embedding an arbitrary
    // value -- e.g. a tab url -- into a JXA template. JSON string syntax is valid
    // JS, so we borrow JSONSerialization and strip the wrapping [ ].
    private func jsStringLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let arr = String(data: data, encoding: .utf8), arr.count >= 2 {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }

    // browser_focus_tab(app, tabId, winId, url, tabIndex, cb): re-resolve the tab by
    // STABLE IDENTITY across ALL windows, then raise its window and activate it.
    // Keys on `tabId` when > 0 (Chrome's stable tab id -- immune to reorder/close/
    // move), else on `url` preferring the `winId` hint and, among equal-url matches
    // there, the listed `tabIndex` (so same-url Safari duplicates stay individually
    // reachable). Position is NEVER primary identity -- it drifts on any tab churn --
    // but on a TOTAL url miss the tab AT the listed (winId, tabIndex) is the
    // last-resort tertiary (Safari navigates in place and has no id): same host as
    // the listed url = that navigation, an honest success with its CURRENT url;
    // different host = likely a closed tab's neighbor, activated best-effort (land
    // near where the tab was) but reported as a miss so the caller alerts + relists.
    // cb gets {"url": "...", "via": "id"|"url"|"pos"} JSON, or {} -> nil when the
    // tab is genuinely gone.
    func browserFocusTab(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app),
              let tabId = LuaState.int(L, 2), let winId = LuaState.int(L, 3),
              let url = LuaState.string(L, 4), let tabIndex = LuaState.int(L, 5) else {
            return luaError(L, "browser_focus_tab: unsupported app or bad args")
        }
        let ref = lua.makeRef(at: 6)
        // Every AX/scripting read is try-guarded (parity with browser_list_tabs) so a
        // single throwing window/tab degrades to "not found", never a script error.
        let script = """
        function run() {
          var app = Application("\(app)");
          app.activate();
          var wantId = \(tabId);
          var wantUrl = \(jsStringLiteral(url));
          var wantIdx = \(tabIndex);
          var isSafari = ("\(app)" === "Safari");
          function activate(win, tab, idx, via) {
            try { win.index = 1; } catch (e) {}    // raise is best-effort
            try {
              if (isSafari) { win.currentTab = tab; }
              else { win.activeTabIndex = idx + 1; }
            } catch (e) {
              // Could not make the tab active -- report an HONEST miss (-> "moved")
              // rather than a false success that stamps MRU while nothing switched.
              return JSON.stringify({});
            }
            var u = "";
            try { u = tab.url() || ""; } catch (e) {}
            return JSON.stringify({ url: u, via: via });
          }
          // scheme://host with credentials/port stripped -- the "same site" signal
          // the positional tertiary keys on (platform.urls.getDomain's intent).
          function hostOf(u) {
            u = u || "";
            var i = u.indexOf("://");
            if (i < 0) return "";
            var h = u.slice(i + 3);
            var e = h.length, q;
            q = h.indexOf("/"); if (q >= 0 && q < e) e = q;
            q = h.indexOf("?"); if (q >= 0 && q < e) e = q;
            q = h.indexOf("#"); if (q >= 0 && q < e) e = q;
            h = h.slice(0, e);
            var at = h.indexOf("@"); if (at >= 0) h = h.slice(at + 1);
            var colon = h.indexOf(":"); if (colon >= 0) h = h.slice(0, colon);
            return h.toLowerCase();
          }
          var fbWin = null, fbTab = null, fbIdx = -1, fbRank = 0;  // best url match: 2 = hinted win, 1 = anywhere
          var posWin = null, posTab = null, posIdx = -1;           // the tab AT the listed (winId, tabIndex)
          var wins = [];
          try { wins = app.windows(); } catch (e) {}
          for (var wi = 0; wi < wins.length; wi++) {
            var win = wins[wi];
            // PRIVACY (defense in depth): never resolve into an incognito window --
            // symmetric with browser_list_tabs, which no longer lists those tabs.
            var m = ""; try { m = win.mode(); } catch (e) {}
            if (m === "incognito") { continue; }
            var wid = -1;
            // Chrome's JXA returns ids as STRINGS -> Number() so === compares to the
            // numeric wantId / winId (a string would never match a number literal).
            try { wid = Number(win.id()) || 0; } catch (e) {}
            var tabs = [];
            try { tabs = win.tabs(); } catch (e) {}
            for (var ti = 0; ti < tabs.length; ti++) {
              var tab = tabs[ti];
              if (wantId > 0) {
                var tid = 0;
                try { tid = Number(tab.id()) || 0; } catch (e) {}
                if (tid === wantId) { return activate(win, tab, ti, "id"); }
              } else {
                var atListed = (wid === \(winId) && ti + 1 === wantIdx);
                if (atListed) { posWin = win; posTab = tab; posIdx = ti; }
                var u = "";
                try { u = tab.url() || ""; } catch (e) {}
                if (u === wantUrl) {
                  if (atListed) { return activate(win, tab, ti, "url"); }  // url AND position: the listed tab itself
                  var rank = (wid === \(winId)) ? 2 : 1;
                  if (rank > fbRank) { fbWin = win; fbTab = tab; fbIdx = ti; fbRank = rank; }
                }
              }
            }
          }
          if (fbTab) { return activate(fbWin, fbTab, fbIdx, "url"); }
          if (posTab) {
            // POSITIONAL TERTIARY: the url matched nowhere, but a tab still sits at
            // the listed position. Same host -> it navigated in place; land it and
            // report its CURRENT url. Different host -> likely a closed tab's
            // neighbor; land there anyway (near where the tab was) but report the
            // honest miss so the caller alerts + stages a relist -- never a silent
            // wrong jump.
            var pu = "";
            try { pu = posTab.url() || ""; } catch (e) {}
            var ph = hostOf(pu);
            if (ph !== "" && ph === hostOf(wantUrl)) {
              return activate(posWin, posTab, posIdx, "pos");
            }
            activate(posWin, posTab, posIdx, "pos");
            return JSON.stringify({});
          }
          return JSON.stringify({});
        }
        """
        lua_pushinteger(L, lua_Integer(runJXA(script, ref)))
        return 1
    }

    // browser_active_url(app, cb) -> resource id; cb(url|nil). ASYNC and
    // OUT-OF-PROCESS -- this is the curated "what is the browser looking at" call
    // (#9 context).
    //
    // IT USED TO BE SYNCHRONOUS, and that was the app's worst main-thread stall
    // (measured 2026-07-25, chasing a Window Fan beachball). "Sync + cheap (one
    // property read)" -- the old comment here -- was simply false:
    //
    //     5 x Chrome, all SUCCEEDING     5.07s total  -> ~1.0s each
    //     1 x Chrome                     6.67s
    //     3 x Safari                     >8.77s
    //     the same script via osascript  0.48s   (out of process, incl. spawn)
    //
    // For scale, a full 36-window AX enumeration is 67ms -- so this ONE property
    // read cost 15x a whole window listing, and was SLOWER in-process than
    // spawning an entire subprocess. usage_stats calls it on EVERY app activation
    // (and tab_switcher on a poll), so a burst of activations -- exactly what
    // window_fan's raise pass produces -- froze the app for seconds at a time.
    //
    // The 2s `with timeout` did NOT bound it (6.67s observed): `with timeout`
    // bounds the Apple Event REPLY only, not NSAppleScript compilation (redone on
    // every call, resolving the target's scripting dictionary), not connection
    // setup, and not the TCC check. There is no ceiling to tune here -- a
    // synchronous main-thread Apple Event is unbounded by construction, which is
    // why CLAUDE.md's seam rule says to prefer the async out-of-process shape for
    // anything bigger than one property read. This IS one property read, and it
    // still needed the subprocess.
    //
    // A subprocess cannot hang the host at all: runJXA owns its own SIGTERM
    // watchdog, and the main thread never waits. Both callers are timer/event
    // SAMPLERS that already tolerate a late answer, so async costs them nothing.
    //
    // PRIVACY -- incognito is NEVER reported. A Chrome window carries a `mode`
    // property ("normal"/"incognito"); when the front window is incognito this
    // bails to "" (-> nil) BEFORE reading the tab URL, so nothing downstream (the
    // usage_stats site column, tab_switcher's MRU) ever sees or records a
    // private-browsing URL. Safari's AppleScript exposes NO private-window flag,
    // so Safari private tabs CANNOT be excluded here -- callers that must honor
    // "never record incognito" treat Safari site context as best-effort
    // (usage_stats gates browser domains behind an opt-in and documents the gap).
    func browserActiveUrl(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app) else {
            // Refuse a non-whitelisted app at the bridge, like browser_list_tabs --
            // never let one reach a script.
            return luaError(L, "browser_active_url: unsupported app")
        }
        let ref = lua.makeRef(at: 2)
        // LIVENESS GATE -- the 2026-07-23 freeze. Kept even though the read is now
        // out-of-process: `Application(x).windows` LAUNCHES a departed app, and
        // usage_stats polls keyed on the last ACTIVATED app, so once Chrome quits
        // every tick would otherwise resurrect it. Answer nil without spawning
        // anything. Fired through the one-shot machinery so the callback contract
        // (exactly once, droppable on teardown) is identical on both paths.
        guard Native.appIsRunning(named: app) else {
            let id = allocOneShot()
            armOneShot(id, ref)
            // fireOneShot already hops to main, so the callback lands AFTER this
            // call returns -- never re-entering Lua mid-call.
            Native.fireOneShot(id, ref) { L in lua_pushnil(L); return 1 }
            lua_pushinteger(L, lua_Integer(id))
            return 1
        }
        // PRIVACY -- incognito is NEVER reported. A Chrome window carries a `mode`
        // property ("normal"/"incognito"); when the front window is incognito this
        // returns "" (-> nil) BEFORE reading the tab URL, so nothing downstream (the
        // usage_stats site column, tab_switcher's MRU) ever sees or records a
        // private-browsing URL. Safari's scripting exposes NO private-window flag,
        // so Safari private tabs CANNOT be excluded here -- callers that must honor
        // "never record incognito" treat Safari site context as best-effort
        // (usage_stats gates browser domains behind an opt-in and documents the gap).
        // This mirrors the guard in browser_list_tabs; keep the two in step.
        let script = app == "Safari"
            ? """
              function run() {
                var app = Application("Safari");
                var docs = app.documents();
                if (docs.length === 0) { return ""; }
                var u = ""; try { u = docs[0].url() || ""; } catch (e) {}
                return u;
              }
              """
            : """
              function run() {
                var app = Application("Google Chrome");
                var wins = app.windows();
                if (wins.length === 0) { return ""; }
                var win = wins[0];
                var mode = ""; try { mode = win.mode(); } catch (e) {}
                if (mode === "incognito") { return ""; }
                var u = ""; try { u = win.activeTab().url() || ""; } catch (e) {}
                return u;
              }
              """
        lua_pushinteger(L, lua_Integer(runJXA(script, ref)))
        return 1
    }
}
